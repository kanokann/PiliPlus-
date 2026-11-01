import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/dynamic_up_tracker.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

Map<String, dynamic> _response(int mid) => {
  'code': 0,
  'data': {
    'has_more': false,
    'items': [
      {
        'id_str': '300',
        'modules': {
          'module_author': {
            'mid': mid,
            'name': 'UP $mid',
            'following': true,
            'pub_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          },
        },
      },
    ],
  },
};

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'test'}),
  null,
  null,
);

void main() {
  late Directory tempDir;
  final trackers = <DynamicUpTracker>[];
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'piliplus-up-tracker-test-',
    );
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    Request();
  });
  setUp(() async {
    Request.dio.interceptors.clear();
    await GStorage.localCache.clear();
  });
  tearDown(() {
    for (final tracker in trackers) {
      tracker.dispose();
    }
    trackers.clear();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'disposed old-account responses cannot update the new account or cache',
    () async {
      final first = _account(1), second = _account(2);
      Accounts.accountMode[AccountType.main.index] = first;
      final started = Completer<void>();
      final delayed = Completer<Map<String, dynamic>>();
      Request.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final account = options.extra['account'] as Account;
            if (identical(account, first)) started.complete();
            final data = identical(account, first)
                ? await delayed.future
                : _response(42);
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: data),
            );
          },
        ),
      );
      var oldChanges = 0, newChanges = 0;
      final old = DynamicUpTracker(
        first,
        onChanged: () => oldChanges++,
        onError: () => fail('stale error'),
      );
      trackers.add(old);
      final pending = old.refresh();
      await started.future;
      old.dispose();
      Accounts.accountMode[AccountType.main.index] = second;
      final current = DynamicUpTracker(
        second,
        onChanged: () => newChanges++,
        onError: () => fail('new error'),
      );
      trackers.add(current);
      await current.refresh();
      delayed.complete(_response(9));
      await pending;
      expect(oldChanges, 0);
      expect(newChanges, 1);
      final data = FollowUpModel.fromUpList(null);
      current.state.apply(data);
      expect(data.upList!.single.mid, 42);
      expect(GStorage.localCache.get('dynamicUpUpdates.v1:1'), isNull);
    },
  );

  test('simultaneous refreshes share one request and a click survives its late response', () async {
    final account = _account(1);
    Accounts.accountMode[AccountType.main.index] = account;
    final started = Completer<void>();
    final delayed = Completer<Map<String, dynamic>>();
    var requests = 0;
    Request.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests++;
          started.complete();
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: await delayed.future,
            ),
          );
        },
      ),
    );
    final tracker = DynamicUpTracker(
      account,
      onChanged: () {},
      onError: () => fail('scan error'),
    );
    trackers.add(tracker);
    final first = tracker.refresh();
    await started.future;
    final second = tracker.refresh();
    tracker.state.markRead(
      42,
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1,
    );
    delayed.complete(_response(42));
    await Future.wait([first, second]);
    expect(requests, 1);
    final data = FollowUpModel.fromUpList({
      'items': [
        {'mid': 42},
      ],
    });
    tracker.state.apply(data);
    expect(data.upList!.single.hasUpdate, isFalse);
  });
}
