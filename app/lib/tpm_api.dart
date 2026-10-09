import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Which Brijj servers the app talks to. Picked on the sign-in page and kept with
/// the session; staging is taken down every night, so production is offered for testing.
enum BrijjEnv {
  staging('Staging', 'stg.rcscbs.com'),
  production('Production', 'brijjworks.com');

  const BrijjEnv(this.label, this.domain);

  final String label;
  final String domain;

  String get companyApi => 'https://company-api.$domain';
  String get tpmApi => 'https://productionsystem-api.$domain';
  String get imsApi => 'https://inventory-api.$domain';

  static BrijjEnv byName(String? name) => values.firstWhere((e) => e.name == name, orElse: () => staging);
}

/// Brijj sign-in and TPM Scan Pull over the API, against [env] (staging or production).
///
/// Users sign in with their own Brijj credentials (company-api SignIn -> 1h JWT +
/// refresh token). The JWT is sent to TPM, so each pull is recorded against that
/// user (TPM's lastUpdatedByUserName). Scan Pull removes items from TPM *and* POS
/// and cannot be undone.
class TpmApi {
  TpmApi(this.env);

  final BrijjEnv env;

  String get companyApi => env.companyApi;
  String get tpmApi => env.tpmApi;
  String get imsApi => env.imsApi;

  /// TPM Portal > Production System permission that allows Scan Pull.
  static const scanPullPermission = 'Item:ScanPull';

  static const _batchSize = 100;
  static const _timeout = Duration(seconds: 60);

  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  Future<BrijjSession> signIn(String username, String password) async {
    final body = await _send('POST', Uri.parse('$companyApi/api/Auth/SignIn'), {
      'userName': username,
      'password': password,
    });
    if (body is! Map || body['isAuthenticated'] != true) {
      throw TpmApiException('Incorrect username or password.');
    }
    final session = BrijjSession(
      accessToken: body['accessToken'] as String,
      refreshToken: body['refreshToken'] as String,
      sessionId: '${body['sessionId']}',
      companyName: '${(body['company'] as Map?)?['name'] ?? ''}',
      env: env,
    );
    if (session.claims['custom:mustchangepasswordonlogin'] == 'True') {
      throw TpmApiException(
        'Your password must be changed before first use. '
        'Sign in to the Brijj portal to change it, then sign in here.',
      );
    }
    return session;
  }

  /// False only when the user's permissions were read and Scan Pull isn't among
  /// them. If they can't be read, TPM still enforces it on submit.
  Future<bool> canScanPull(BrijjSession session) async {
    try {
      final apps = await _send(
        'GET',
        Uri.parse('$companyApi/api/Users/${session.userId}/Permissions'),
        null,
        session.accessToken,
      );
      for (final app in apps as List) {
        for (final group in app['permissionGroups'] as List? ?? const []) {
          for (final p in group['permissions'] as List? ?? const []) {
            if (p['name'] == scanPullPermission) return true;
          }
        }
      }
      return false;
    } on TpmApiException {
      return true;
    }
  }

  /// The user's profile picture URL (company-api Users/{id}/Lite `profileFileUrl`, as the
  /// Brijj portals use), or null when they haven't set one.
  Future<String?> profilePhotoUrl(BrijjSession session) async {
    await _ensureFresh(session);
    final body = await _send(
      'GET',
      Uri.parse('$companyApi/api/Users/${session.userId}/Lite'),
      null,
      session.accessToken,
    );
    final url = body is Map ? '${body['profileFileUrl'] ?? ''}'.trim() : '';
    return url.isEmpty ? null : url;
  }

  /// Downloads [url] (a profile picture); null if it can't be fetched or isn't an image.
  Future<List<int>?> download(String url) async {
    try {
      final req = await _http.getUrl(Uri.parse(url)).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200 ||
          !(res.headers.contentType?.primaryType == 'image' ||
              res.headers.contentType == null ||
              res.headers.contentType?.mimeType == 'application/octet-stream')) {
        await res.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in res.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 5 * 1024 * 1024) return null; // not a profile picture
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// A fresh access token when the current one is within 2 minutes of expiry.
  Future<void> _ensureFresh(BrijjSession session) async {
    if (DateTime.now().isBefore(session.expiresAt.subtract(const Duration(minutes: 2)))) return;
    final body = await _send('POST', Uri.parse('$companyApi/api/Auth/Refresh'), {'refreshToken': session.refreshToken});
    final token = body is Map ? body['accessToken'] : null;
    if (token is! String || token.isEmpty) throw SessionExpiredException();
    session.accessToken = token;
  }

  Future<void> signOut(BrijjSession session) async {
    try {
      await _send('POST', Uri.parse('$companyApi/api/Auth/SignOut'), {
        'userId': int.tryParse(session.userId),
        'sessionId': session.sessionId,
      }, session.accessToken);
    } on TpmApiException {
      // Signing out locally is what matters; the server session expires on its own.
    }
  }

  /// TPM's production record for [barcode] (exact match), or null if TPM has none.
  Future<ItemDetails?> lookup(BrijjSession session, String barcode) async {
    await _ensureFresh(session);
    final uri = Uri.parse('$tpmApi/api/ProductionHistory').replace(
      queryParameters: {
        'barcode': barcode,
        'includeDeleted': 'true', // required — the endpoint errors without it
        'pageSize': '5',
      },
    );
    final body = await _send('GET', uri, null, session.accessToken);
    final items = (body is Map ? body['items'] : body) as List? ?? const [];
    for (final item in items) {
      if (item is Map && item['barcode'] == barcode) return ItemDetails(item.cast<String, dynamic>());
    }
    return null;
  }

  /// Company week colors by production cycle id, e.g. 531 -> "Green".
  Future<Map<int, String>> colorNames(BrijjSession session) async {
    await _ensureFresh(session);
    final uri = Uri.parse('$tpmApi/api/ProductionCycle').replace(queryParameters: {'CompanyId': session.companyId});
    final body = await _send('GET', uri, null, session.accessToken);
    return {
      for (final c in body as List? ?? const [])
        if (c is Map && c['id'] is num && c['displayName'] != null) (c['id'] as num).toInt(): '${c['displayName']}',
    };
  }

  /// Week number of the production cycle in effect on [date] (yyyy-mm-dd), or null.
  Future<int?> weekNumber(BrijjSession session, String date) async {
    await _ensureFresh(session);
    final uri = Uri.parse('$tpmApi/api/ProductionCycle/ByDate')
        .replace(queryParameters: {'CompanyId': session.companyId, 'Date': date});
    final body = await _send('GET', uri, null, session.accessToken);
    return body is Map ? (body['weekNumber'] as num?)?.toInt() : null;
  }

  /// IMS locations whose location profile is a Scan Pull profile (moving an item
  /// there pulls it from TPM and POS), e.g. "Memphis / Scan Pull - Memphis". Empty
  /// when the company has none set up — then the app falls back to TPM Scan Pull.
  Future<List<ScanPullLocation>> scanPullLocations(BrijjSession session) async {
    await _ensureFresh(session);
    final uri = Uri.parse('$imsApi/api/WarehouseLocations/Lite')
        .replace(queryParameters: {'CompanyId': session.companyId});
    final body = await _send('GET', uri, null, session.accessToken);
    final all = [
      for (final l in body as List? ?? const [])
        if (l is Map && l['warehouse'] is Map) l,
    ];
    // The Lite/list responses report isScanPull=false for every profile; only a
    // profile fetched by id has the real flag.
    final scanPullProfiles = <int>{};
    for (final id in {
      for (final l in all)
        if ((l['warehouseLocationProfile'] as Map?)?['id'] case final num id) id.toInt(),
    }) {
      final profile = await _send(
        'GET',
        Uri.parse('$imsApi/api/WarehouseLocationProfiles/$id'),
        null,
        session.accessToken,
      );
      if (profile is Map && profile['isScanPull'] == true) scanPullProfiles.add(id);
    }
    return [
      for (final l in all)
        if (scanPullProfiles.contains(((l['warehouseLocationProfile'] as Map?)?['id'] as num?)?.toInt()))
          ScanPullLocation(
            id: (l['id'] as num).toInt(),
            name: '${l['name']}',
            warehouseId: ((l['warehouse'] as Map)['id'] as num).toInt(),
            warehouseName: '${(l['warehouse'] as Map)['name']}',
            // Every warehouse is searched when locating a scanned item in IMS.
            allWarehouseIds: {for (final w in all) ((w['warehouse'] as Map)['id'] as num).toInt()}.toList(),
            // Items may only be pulled from a sales floor in the same warehouse.
            salesFloorIds: [
              for (final f in all)
                if ((f['warehouse'] as Map)['id'] == (l['warehouse'] as Map)['id'] && _isSalesFloor(f))
                  (f['id'] as num).toInt(),
            ],
          ),
    ]..sort((a, b) => a.label.compareTo(b.label));
  }

  /// A sales floor location: "Sales Floor" in the location's or its profile's name.
  static bool _isSalesFloor(Map l) =>
      '${l['name']} ${(l['warehouseLocationProfile'] as Map?)?['name']}'.toLowerCase().contains('sales floor');

  /// Where [barcode] is in IMS: one entry per warehouse location holding it.
  Future<List<ImsSerial>> imsFind(BrijjSession session, String barcode, List<int> warehouseIds) async {
    await _ensureFresh(session);
    final found = <ImsSerial>[];
    for (final w in warehouseIds) {
      final uri = Uri.parse('$imsApi/api/ProductSerials').replace(
        queryParameters: {'CompanyId': session.companyId, 'WarehouseId': '$w', 'SearchTerm': barcode, 'PageSize': '10'},
      );
      final body = await _send('GET', uri, null, session.accessToken);
      for (final s in (body as Map)['items'] as List? ?? const []) {
        if (s is Map && s['serialNumber'] == barcode && ((s['quantity'] as num?) ?? 0) > 0) {
          found.add(ImsSerial.fromJson(s.cast<String, dynamic>(), w));
        }
      }
    }
    return found;
  }

  /// Moves each item into [dest] with an IMS quick movement order (as IMS Quick
  /// Relocation does), recorded as the signed-in user. Returns one result per barcode.
  Future<List<ScanPullResult>> moveToLocation(
    BrijjSession session,
    ScanPullLocation dest,
    Map<String, ImsSerial> items,
  ) async {
    final results = <ScanPullResult>[];
    final entries = items.entries.toList();
    for (var i = 0; i < entries.length; i += _batchSize) {
      await _ensureFresh(session);
      final batch = entries.sublist(i, (i + _batchSize).clamp(0, entries.length));
      final body = await _send('POST', Uri.parse('$imsApi/api/MovementOrders/Quick'), {
        'type': 1, // Relocate
        'relocationType': 3, // Product (IMS sends serial-barcode relocations as Product)
        'priority': 3, // High
        'status': 2,
        'movementOrderProcessType': 2, // Quick
        'reason': 'Scan Pull',
        'warehouseId': dest.warehouseId,
        'companyId': int.tryParse(session.companyId) ?? session.companyId,
        'items': [
          for (final e in batch)
            {
              'status': 1, // Pending
              'sourceWarehouseLocationId': e.value.locationId,
              'destinationWarehouseLocationId': dest.id,
              'productId': e.value.productId,
              'licensePlateId': null,
              'quantity': 1,
              'movementOrderItemLocationQuantities': null,
              'serials': [
                {'productSerialId': e.value.serialId},
              ],
            },
        ],
      }, session.accessToken);
      final order = body is Map ? body : const {};
      final ref = order['referenceNumber'] ?? 'movement order';
      // Movement order status: 3 Queued, 5 Completed, 6 Cancelled, 7 Failed.
      final status = (order['status'] as num?)?.toInt();
      final error = switch (status) {
        5 || 3 => null,
        6 => 'Movement cancelled ($ref)',
        7 => 'Movement failed ($ref)',
        _ => null,
      };
      for (final e in batch) {
        results.add(ScanPullResult(e.key, error, note: status == 3 ? 'Queued in $ref' : '$ref'));
      }
    }
    return results;
  }

  /// Pulls [barcodes] as the signed-in user; returns one result per barcode, in order.
  Future<List<ScanPullResult>> scanPull(BrijjSession session, List<String> barcodes) async {
    await _ensureFresh(session);
    final failed = <String, String>{};
    for (var i = 0; i < barcodes.length; i += _batchSize) {
      final batch = barcodes.sublist(i, (i + _batchSize).clamp(0, barcodes.length));
      final body = await _send('PUT', Uri.parse('$tpmApi/api/Productionworking/barcodes'), batch, session.accessToken);
      for (final f in (body as Map)['failedToDeleteSerials'] as List? ?? const []) {
        failed['${f['serialNumber']}'] = '${f['message'] ?? 'Failed'}';
      }
    }
    return [for (final b in barcodes) ScanPullResult(b, failed[b])];
  }

  Future<dynamic> _send(String method, Uri uri, Object? payload, [String? token]) async {
    try {
      final req = await _http.openUrl(method, uri).timeout(_timeout);
      req.headers.contentType = ContentType.json;
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (payload != null) req.write(jsonEncode(payload));
      final res = await req.close().timeout(_timeout);
      final text = await res.transform(utf8.decoder).join().timeout(_timeout);
      if (res.statusCode == 401) throw SessionExpiredException();
      if (res.statusCode == 403) {
        throw TpmApiException(
          'Your Brijj account is not allowed to do this '
          '(Scan Pull needs the $scanPullPermission permission).',
        );
      }
      // Any 2xx is success — e.g. IMS answers 201 Created for a new movement order.
      if (res.statusCode < 200 || res.statusCode > 299) {
        throw TpmApiException(
          'HTTP ${res.statusCode} from ${uri.path}\n'
          '${text.length > 300 ? text.substring(0, 300) : text}',
        );
      }
      return text.isEmpty ? null : jsonDecode(text);
    } on TpmApiException {
      rethrow;
    } on SocketException {
      throw OfflineException();
    } on TimeoutException {
      throw OfflineException();
    } on HandshakeException {
      throw OfflineException();
    } on HttpException {
      throw OfflineException();
    } catch (e) {
      throw TpmApiException('Could not reach ${uri.host}: $e');
    }
  }

  void close() => _http.close();
}

/// A signed-in Brijj user. Saved on the device (app-private storage) so the user
/// stays signed in until they sign out or the refresh token stops working.
class BrijjSession {
  BrijjSession({
    required this.accessToken,
    required this.refreshToken,
    required this.sessionId,
    required this.companyName,
    this.env = BrijjEnv.staging,
  });

  String accessToken;
  final String refreshToken;
  final String sessionId;
  final String companyName;

  /// The servers this user signed in to; every call for the session goes there.
  final BrijjEnv env;

  /// Company name plus the environment, e.g. "Whiskers (staging)".
  String get companyLabel => '$companyName (${env.label.toLowerCase()})';

  Map<String, dynamic> get claims {
    var part = accessToken.split('.')[1];
    part += '=' * ((4 - part.length % 4) % 4);
    return jsonDecode(utf8.decode(base64Url.decode(part))) as Map<String, dynamic>;
  }

  String get userId => '${claims['custom:userid'] ?? claims['sub']}';

  String get companyId => '${claims['custom:companyid'] ?? ''}';

  String get fullName {
    final name = '${claims['custom:fullname'] ?? ''}'.trim();
    return name.isEmpty ? 'User $userId' : name;
  }

  DateTime get expiresAt => DateTime.fromMillisecondsSinceEpoch(((claims['exp'] as num?) ?? 0).toInt() * 1000);

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'sessionId': sessionId,
    'companyName': companyName,
    'env': env.name,
  };

  static BrijjSession fromJson(Map<String, dynamic> j) => BrijjSession(
    accessToken: j['accessToken'] as String,
    refreshToken: j['refreshToken'] as String,
    sessionId: j['sessionId'] as String,
    companyName: j['companyName'] as String,
    // Sessions saved before the environment switch existed are staging.
    env: BrijjEnv.byName(j['env'] as String?),
  );
}

/// One produced item, from TPM ProductionHistory.
class ItemDetails {
  ItemDetails(this._j);

  final Map<String, dynamic> _j;

  String? _s(String key) {
    final v = _j[key];
    return v == null || '$v'.trim().isEmpty ? null : '$v'.trim();
  }

  String get department => _s('departmentDescr') ?? '';
  String get category => _s('categoryName') ?? '';
  String? get subCategory => _s('subCategoryName');
  String? get brand => _s('brandDescr');
  String? get size => _s('sizeDescr');
  String? get quality => _s('qualityDescr');
  String? get store => _s('currentStoreName') ?? _s('storeName');
  String? get location => _s('locationName');
  String? get producedBy => _s('userName');
  double get price => (_j['price'] as num?)?.toDouble() ?? 0;
  DateTime? get produced => DateTime.tryParse('${_j['dateCreated']}');

  /// Week color tag, e.g. "#3a7a29".
  String? get color => _s('color');

  /// Week color name, when TPM includes it (usually it doesn't — see [productionCycleId]).
  String? get colorName => _s('displayName');
  int? get productionCycleId => (_j['productionCycleId'] as num?)?.toInt();

  /// Produced date as yyyy-mm-dd, for the week-number lookup.
  String? get producedDay {
    final p = produced;
    if (p == null) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${p.year}-${two(p.month)}-${two(p.day)}';
  }

  Map<String, dynamic> toJson() => _j;

  bool get alreadyPulled => _j['isScanPull'] == true;
  bool get deleted => _j['isDeleted'] == true;

  /// Why this item can't be pulled, or null if it can.
  String? get problem => alreadyPulled
      ? 'Already scan pulled'
      : deleted
      ? 'Deleted in TPM'
      : null;
}

/// An IMS location with a Scan Pull location profile.
class ScanPullLocation {
  ScanPullLocation({
    required this.id,
    required this.name,
    required this.warehouseId,
    required this.warehouseName,
    required this.allWarehouseIds,
    required this.salesFloorIds,
  });

  final int id;
  final String name;
  final int warehouseId;
  final String warehouseName;

  /// All of the company's warehouses, searched to find where a scanned item is.
  final List<int> allWarehouseIds;

  /// Sales floor locations in this warehouse — the only places items are pulled from.
  final List<int> salesFloorIds;

  String get label => '$warehouseName / $name';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'warehouseId': warehouseId,
    'warehouseName': warehouseName,
    'allWarehouseIds': allWarehouseIds,
    'salesFloorIds': salesFloorIds,
  };

  static ScanPullLocation fromJson(Map<String, dynamic> j) => ScanPullLocation(
    id: (j['id'] as num).toInt(),
    name: '${j['name']}',
    warehouseId: (j['warehouseId'] as num).toInt(),
    warehouseName: '${j['warehouseName']}',
    allWarehouseIds: [for (final w in j['allWarehouseIds'] as List? ?? const []) (w as num).toInt()],
    salesFloorIds: [for (final w in j['salesFloorIds'] as List? ?? const []) (w as num).toInt()],
  );
}

/// A scanned item's serial record in IMS, at one location.
class ImsSerial {
  ImsSerial({
    required this.serialId,
    required this.productId,
    required this.locationId,
    required this.locationName,
    required this.warehouseId,
  });

  final int serialId;
  final int productId;
  final int locationId;
  final String locationName;
  final int warehouseId;

  static ImsSerial fromJson(Map<String, dynamic> j, int warehouseId) => ImsSerial(
    serialId: (j['id'] as num).toInt(),
    productId: (j['productId'] as num).toInt(),
    locationId: (j['warehouseLocationId'] as num).toInt(),
    locationName: '${(j['warehouseLocation'] as Map?)?['name'] ?? j['warehouseLocationId']}',
    warehouseId: warehouseId,
  );

  Map<String, dynamic> toJson() => {
    'id': serialId,
    'productId': productId,
    'warehouseLocationId': locationId,
    'warehouseLocation': {'name': locationName},
    'warehouseId': warehouseId,
  };
}

class ScanPullResult {
  ScanPullResult(this.barcode, this.error, {this.note});

  final String barcode;

  /// Extra detail for a pulled item, e.g. the IMS movement order reference.
  final String? note;

  /// Why the barcode wasn't pulled (e.g. "Barcode not found."), or null if pulled.
  final String? error;

  bool get pulled => error == null;
}

class TpmApiException implements Exception {
  TpmApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// No network (or TPM unreachable) — retry when back online.
class OfflineException extends TpmApiException {
  OfflineException() : super('No connection to TPM.');
}

/// The refresh token no longer works (or TPM rejected the token): sign in again.
class SessionExpiredException extends TpmApiException {
  SessionExpiredException() : super('Your sign-in has expired. Please sign in again.');
}
