import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/utils/parse_int.dart';

class _UpUpdate {
  _UpUpdate(this.up);

  final UpItem up;
  int id = 0, time = 0, readId = 0, readAt = 0;
  bool official = false, dismissed = false, unfollowed = false;

  bool get unread =>
      !unfollowed &&
      (official && !dismissed || id > readId && (time == 0 || time >= readAt));

  bool get hasLocalState =>
      id != 0 || readId != 0 || readAt != 0 || dismissed || unfollowed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time,
    'name': up.uname,
    'face': up.face,
    'read': readId,
    'read_at': readAt,
    'dismissed': dismissed,
    'unfollowed': unfollowed,
  };
}

/// Author-level read evidence is independent of the server's feed read state.
class DynamicUpUpdates {
  int baseline = 0;
  int _target = 0, _since = 0;
  String? _offset;
  final _visited = <String>{};
  final _authors = <int, _UpUpdate>{};

  bool get hasPending => _offset != null;

  _UpUpdate _author(int mid) =>
      _authors.putIfAbsent(mid, () => _UpUpdate(UpItem(mid: mid)));

  Future<LoadingState<bool>> scan(
    Future<LoadingState<DynamicsDataModel>> Function(String? offset) loadPage, {
    required int now,
    int maxPages = 4,
  }) async {
    if (baseline == 0 && _since == 0) {
      _since = now - const Duration(days: 7).inSeconds;
    }
    for (var count = 0; count < maxPages; count++) {
      final result = await loadPage(_offset);
      if (result is! Success<DynamicsDataModel>) {
        return result is Error ? result : const Error('更新动态加载失败');
      }
      final page = result.response;
      final items = page.items ?? const <DynamicItemModel>[];
      if (_target == 0) {
        _target = page.updateBaseline;
        for (final item in items) {
          final id = safeToInt(item.idStr) ?? 0;
          if (id > _target) _target = id;
        }
      }
      for (final item in items) {
        final author = item.modules.moduleAuthor;
        final mid = author?.mid ?? 0;
        if (mid <= 0) continue;
        final state = _author(mid);
        if (author!.following == false) {
          state
            ..id = 0
            ..official = false
            ..dismissed = false
            ..unfollowed = true;
          continue;
        }
        if (author.following != true) continue;
        state.unfollowed = false;
        final id = safeToInt(item.idStr) ?? 0;
        final time = author.pubTs ?? 0;
        if (id <= baseline ||
            id <= state.id ||
            baseline == 0 && time < _since) {
          continue;
        }
        state
          ..id = id
          ..time = time;
        state.up
          ..uname = author.name
          ..face = author.face;
      }
      final ordered = items.where(
        (item) => item.modules.moduleAuthor?.isTop != true,
      );
      final passed =
          ordered.isNotEmpty &&
          ordered.every(
            (item) => baseline > 0
                ? (safeToInt(item.idStr) ?? 0) > 0 &&
                      (safeToInt(item.idStr) ?? 0) <= baseline
                : (item.modules.moduleAuthor?.pubTs ?? 0) > 0 &&
                      item.modules.moduleAuthor!.pubTs! < _since,
          );
      if (page.hasMore != true || passed) {
        if (_target > baseline) baseline = _target;
        _target = 0;
        _offset = null;
        _visited.clear();
        return const Success(true);
      }
      final next = page.offset;
      if (next == null ||
          next.isEmpty ||
          next == _offset ||
          !_visited.add(next)) {
        _target = 0;
        _offset = null;
        _visited.clear();
        return const Error('更新动态分页未推进，请刷新重试');
      }
      _offset = next;
    }
    return const Success(false);
  }

  void applyOfficial(Iterable<UpItem> ups, {bool replace = true}) {
    if (replace) {
      for (final state in _authors.values) {
        state.official = false;
      }
    }
    for (final up in ups) {
      final state = _author(up.mid);
      if (state.unfollowed) continue;
      state.up
        ..uname = up.uname ?? state.up.uname
        ..face = up.face ?? state.up.face;
      if (up.hasUpdate != null) {
        state.official = up.hasUpdate!;
        if (!state.official) state.dismissed = false;
      }
    }
  }

  void markRead(int mid, int now) {
    if (mid <= 0) return;
    final state = _author(mid);
    if (state.id > state.readId) state.readId = state.id;
    if (now > state.readAt) state.readAt = now;
    state.dismissed = true;
  }

  void apply(FollowUpModel data, {bool sort = true}) {
    final list = (data.upList ??= [])
      ..removeWhere((up) => _authors[up.mid]?.unfollowed == true);
    final mids = {for (final up in list) up.mid};
    for (final state in _authors.values) {
      if (state.unread && mids.add(state.up.mid)) {
        list.add(
          UpItem(mid: state.up.mid, uname: state.up.uname, face: state.up.face),
        );
      }
    }
    for (final up in list) {
      up.hasUpdate = _authors[up.mid]?.unread ?? false;
    }
    if (!sort) return;
    final positions = {for (final (i, up) in list.indexed) up.mid: i};
    list.sort((a, b) {
      final unread = (b.hasUpdate! ? 1 : 0).compareTo(a.hasUpdate! ? 1 : 0);
      if (unread != 0) return unread;
      if (a.hasUpdate!) {
        final latest = (_authors[b.mid]?.id ?? 0).compareTo(
          _authors[a.mid]?.id ?? 0,
        );
        if (latest != 0) return latest;
      }
      return positions[a.mid]!.compareTo(positions[b.mid]!);
    });
  }

  Map<String, dynamic> toJson() => {
    'baseline': baseline,
    'target': _target,
    'since': _since,
    'offset': _offset,
    'visited': _visited.toList(),
    'authors': {
      for (final entry in _authors.entries)
        if (entry.value.hasLocalState) '${entry.key}': entry.value.toJson(),
    },
  };

  static DynamicUpUpdates fromJson(dynamic json) {
    final state = DynamicUpUpdates();
    if (json is! Map) return state;
    state
      ..baseline = safeToInt(json['baseline']) ?? 0
      .._since = safeToInt(json['since']) ?? 0
      .._offset = json['offset'] as String?;
    if (state.hasPending) state._target = safeToInt(json['target']) ?? 0;
    if (json['visited'] case final List visited) {
      state._visited.addAll(visited.whereType<String>());
    }
    if (json['authors'] case final Map authors) {
      for (final entry in authors.entries) {
        final mid = safeToInt(entry.key) ?? 0;
        if (mid <= 0 || entry.value is! Map) continue;
        final raw = entry.value as Map;
        state._author(mid)
          ..id = safeToInt(raw['id']) ?? 0
          ..time = safeToInt(raw['time']) ?? 0
          ..readId = safeToInt(raw['read']) ?? 0
          ..readAt = safeToInt(raw['read_at']) ?? 0
          ..dismissed = raw['dismissed'] == true
          ..unfollowed = raw['unfollowed'] == true
          ..up.uname = raw['name'] as String?
          ..up.face = raw['face'] as String?;
      }
    } else {
      // Migrate the previous custom build without losing local read evidence.
      for (final raw in json['latest'] as List? ?? const []) {
        final author = raw['modules']['module_author'];
        final mid = safeToInt(author['mid']) ?? 0;
        state._author(mid)
          ..id = safeToInt(raw['id_str']) ?? 0
          ..time = safeToInt(author['pub_ts']) ?? 0
          ..up.uname = author['name'] as String?
          ..up.face = author['face'] as String?;
      }
      for (final entry in (json['read_ids'] as Map? ?? const {}).entries) {
        state._author(safeToInt(entry.key)!).readId =
            safeToInt(entry.value) ?? 0;
      }
      for (final entry in (json['read_at'] as Map? ?? const {}).entries) {
        state._author(safeToInt(entry.key)!).readAt =
            safeToInt(entry.value) ?? 0;
      }
      for (final mid in json['dismissed'] as List? ?? const []) {
        state._author(safeToInt(mid)!).dismissed = true;
      }
      for (final mid in json['unfollowed'] as List? ?? const []) {
        state._author(safeToInt(mid)!).unfollowed = true;
      }
    }
    return state;
  }
}
