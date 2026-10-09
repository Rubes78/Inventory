import 'tpm_api.dart';

/// What TPM (and, for a location destination, IMS) says about a scanned barcode.
class Lookup {
  const Lookup._({
    this.details,
    this.ims,
    this.error,
    this.loading = false,
    this.waiting = false,
    this.notFound = false,
  });

  /// Being looked up now; [details]/[ims] are the last known ones, if any.
  const Lookup.checking([ItemDetails? details, List<ImsSerial>? ims])
    : this._(details: details, ims: ims, loading: true);

  /// Offline: will be looked up when back online; shows the last known details, if any.
  const Lookup.waiting([ItemDetails? details, List<ImsSerial>? ims])
    : this._(details: details, ims: ims, waiting: true);
  const Lookup.found(ItemDetails d, [List<ImsSerial>? ims]) : this._(details: d, ims: ims);
  static const missing = Lookup._(notFound: true);
  const Lookup.failed(String error, [ItemDetails? details, List<ImsSerial>? ims])
    : this._(details: details, ims: ims, error: error);

  final ItemDetails? details;

  /// Where the item is in IMS (null = not checked; only checked for a location destination).
  final List<ImsSerial>? ims;

  /// The lookup failed for a reason other than being offline.
  final String? error;
  final bool loading;
  final bool waiting;
  final bool notFound;

  /// The IMS record to move into [dest] — only from a sales floor in its warehouse.
  ImsSerial? source(ScanPullLocation dest) {
    for (final s in ims ?? const <ImsSerial>[]) {
      if (dest.salesFloorIds.contains(s.locationId)) return s;
    }
    return null;
  }

  /// Why this barcode won't be submitted to [dest] (null = TPM Scan Pull), or null if it will be.
  String? skipReason([ScanPullLocation? dest]) {
    if (notFound) return 'Not found in TPM';
    if (details?.problem case final p?) return p;
    final where = ims;
    if (dest == null || where == null) return null;
    if (where.isEmpty) return 'Not in IMS inventory';
    if (where.any((s) => s.locationId == dest.id)) return 'Already in ${dest.name}';
    if (source(dest) == null) {
      return 'Not on the ${dest.warehouseName} sales floor (${where.map((s) => s.locationName).toSet().join(', ')})';
    }
    return null;
  }

  Map<String, dynamic>? toJson() => notFound
      ? {'notFound': true}
      : details == null
      ? null
      : {
          'item': details!.toJson(),
          if (ims != null) 'ims': [for (final x in ims!) x.toJson()],
        };

  static Lookup? fromJson(Map<String, dynamic> j) {
    if (j['notFound'] == true) return missing;
    if (j['item'] is! Map) return null;
    final ims = j['ims'] is List
        ? [
            for (final x in j['ims'] as List)
              ImsSerial.fromJson((x as Map).cast<String, dynamic>(), ((x)['warehouseId'] as num).toInt()),
          ]
        : null;
    return Lookup.found(ItemDetails((j['item'] as Map).cast<String, dynamic>()), ims);
  }
}
