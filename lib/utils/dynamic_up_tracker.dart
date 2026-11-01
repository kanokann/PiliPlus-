import 'dart:async';

import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/dynamics/up_updates.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';

/// Owns one account's scan, cache writes and background continuation.
class DynamicUpTracker {
  DynamicUpTracker(
    this.account, {
    required this.onChanged,
    required this.onError,
  }) : state = DynamicUpUpdates.fromJson(
         GStorage.localCache.get('dynamicUpUpdates.v1:${account.mid}'),
       );

  final Account account;
  final DynamicUpUpdates state;
  final void Function() onChanged, onError;
  bool _active = true;
  Timer? _timer;
  Future<void>? _pending;
  Future<void> _writes = Future.value();

  bool get isCurrent => _active && identical(account, Accounts.main);

  void dispose() {
    _active = false;
    _timer?.cancel();
  }

  void save() {
    final snapshot = state.toJson();
    _writes = _writes.then((_) async {
      try {
        await GStorage.localCache.put(
          'dynamicUpUpdates.v1:${account.mid}',
          snapshot,
        );
      } catch (_) {
        // A temporary storage failure must not discard in-memory read evidence.
      }
    });
  }

  void markRead(int mid) {
    state.markRead(mid, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    save();
  }

  Future<void> refresh() {
    _timer?.cancel();
    return _pending ??= _scan().whenComplete(() => _pending = null);
  }

  Future<void> _scan() async {
    final continuing = state.hasPending;
    try {
      final result = await state.scan((offset) async {
        if (!isCurrent) return const Error('账号已切换');
        final result = await DynamicsHttp.followDynamic(
          account: account,
          offset: offset,
          forUpdateTracking: true,
        );
        return isCurrent ? result : const Error('账号已切换');
      }, now: DateTime.now().millisecondsSinceEpoch ~/ 1000);
      if (!isCurrent) return;
      save();
      onChanged();
      if (result is! Success<bool>) {
        onError();
      } else if (state.hasPending || continuing) {
        // A final fresh pass catches updates published during a long backfill.
        _timer = Timer(const Duration(seconds: 1), () {
          if (isCurrent) unawaited(refresh());
        });
      }
    } catch (_) {
      if (isCurrent) onError();
    }
  }
}
