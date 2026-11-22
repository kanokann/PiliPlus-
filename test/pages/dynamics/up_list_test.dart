import 'package:PiliPlus/grpc/bilibili/app/dynamic/v2.pb.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('last read UP follows every unread UP until it gets a new update', () {
    final lastRead = UpItem(mid: 2, hasUpdate: false);
    for (final updated in [false, true]) {
      final panel =
          FollowUpModel.fromUpList({
              'items': [
                {'mid': 3, 'has_update': false},
                {'mid': 1, 'has_update': true},
                {'mid': 4, 'has_update': true},
              ],
            })
            ..prependUnread(
              [MixUpListItem(uid: Int64(2), reddotState: updated ? 1 : 0)],
              {},
              lastRead: lastRead,
            )
            ..sortUnread({1: 30, 2: 40}, lastReadMid: lastRead.mid);

      expect(
        panel.upList!.map((up) => up.mid),
        updated ? [2, 1, 4, 3] : [1, 4, 2, 3],
      );
    }
  });

  test('sorts dated unread authors before undated unread and read authors', () {
    final panel = FollowUpModel.fromUpList({
      'items': [
        for (final mid in [1, 2, 3, 4]) {'mid': mid, 'has_update': mid != 4},
      ],
    })..sortUnread({1: 30, 2: 40, 4: 100});
    expect(panel.upList!.map((up) => up.mid), [2, 1, 3, 4]);
  });

  test(
    'merge unread UPs ahead of portal entries, respecting taps during refresh',
    () {
      final portal =
          FollowUpModel.fromUpList({
              'items': [
                {'mid': 1},
                {'mid': 2, 'has_update': false},
                {'mid': 3, 'has_update': true},
                {'mid': 4, 'has_update': true},
              ],
            })
            ..prependUnread(
              [
                for (final mid in [5, 2, 4])
                  MixUpListItem(uid: Int64(mid), reddotState: 1),
                MixUpListItem(uid: Int64(6), reddotState: 0),
              ],
              {4},
            )
            ..sortUnread(const {});

      expect(portal.upList!.map((up) => up.mid), [5, 2, 3, 4, 1]);
      expect(
        portal.upList!.where((up) => up.hasUpdate == true).map((up) => up.mid),
        [5, 2, 3],
      );
    },
  );
}
