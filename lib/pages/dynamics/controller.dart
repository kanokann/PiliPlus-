import 'dart:async';

import 'package:PiliPlus/grpc/dyn.dart';
import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' show TabController;

class DynamicsController
    extends CommonDataController<FollowUpModel, FollowUpModel>
    with GetSingleTickerProviderStateMixin, AccountMixin {
  late final TabController tabController;

  final Set<int> tempBannedList = <int>{};

  String? _offset;
  late int _page = 1;
  late bool _isEnd = false;
  Set<UpItem>? _cacheUpList;
  final _publicationTimes = <int, int>{};
  UpItem? _lastReadUp;
  var _markingRead = <int>{};
  Set<int>? _readDuringRefresh;
  bool _firstPage = true;
  Future<void>? _feedRefresh;
  late int _requestMid;
  late Future<void> _request;
  late int hostMid = -1, currentMid = -1;
  late bool showLiveUp = Pref.expandDynLivePanel;
  late final _showAllUp = Pref.dynamicsShowAllFollowedUp;
  bool get _useAppUnread =>
      _showAllUp && !Accounts.main.accessKey.isNullOrEmpty;

  bool get _keepPanel =>
      _showAllUp &&
      currentMid != -1 &&
      tabController.index == DynamicsTabType.up.index &&
      loadingState.value.isSuccess;

  void recordPublications(
    List<DynamicItemModel>? items, {
    required bool firstPage,
  }) {
    if (isClosed || !_showAllUp || items == null) return;
    var changed = false;
    for (final item in items) {
      final author = item.modules.moduleAuthor;
      final mid = author?.mid;
      final time = author?.pubTs ?? 0;
      if (mid == null || time <= (_publicationTimes[mid] ?? 0)) continue;
      _publicationTimes[mid] = time;
      changed = true;
    }
    if (changed && firstPage && !isLoading && !_keepPanel) {
      _sortVisiblePanel();
    }
  }

  void _sortVisiblePanel() {
    if (loadingState.value.dataOrNull case final panel?) {
      panel.sortUnread(_publicationTimes, lastReadMid: _lastReadUp?.mid);
      loadingState.refresh();
    }
  }

  final upPanelPosition = Pref.upPanelPosition;

  @override
  final AccountService accountService = Get.find<AccountService>();

  DynamicsTabController? get controller {
    try {
      return Get.find<DynamicsTabController>(
        tag: DynamicsTabType.values[tabController.index].name,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void onInit() {
    super.onInit();
    tabController = TabController(
      vsync: this,
      length: DynamicsTabType.values.length,
      initialIndex: Pref.defaultDynamicTypeIndex,
    );
    queryData();
  }

  void _jumpToTab(int mid) {
    tabController.index = mid == -1 ? 0 : 4;
  }

  void onSelectUp(UpItem item) {
    final mid = item.mid;
    if (_showAllUp && item.hasUpdate == true) _lastReadUp = item;
    if (item.hasUpdate == true && _useAppUnread) {
      final marking = _markingRead;
      _readDuringRefresh?.add(mid);
      if (marking.add(mid)) {
        unawaited(
          DynGrpc.markUpRead(mid).whenComplete(() => marking.remove(mid)),
        );
      }
    }
    item.hasUpdate = false;
    if (currentMid == mid) {
      _jumpToTab(mid);
      if (mid == -1) {
        singleRefresh();
      }
      controller?.onReload();
      return;
    }

    if (mid != -1) {
      hostMid = mid;
      try {
        Get.find<DynamicsTabController>(
          tag: DynamicsTabType.up.name,
        ).onReload();
      } catch (_) {}
    }

    currentMid = mid;
    _jumpToTab(mid);
    if (mid == -1 && _showAllUp) singleRefresh();
  }

  Future<void> singleRefresh([Future<void>? feed]) async {
    if (isClosed || _keepPanel) return;
    if (isLoading) {
      if (_firstPage && _requestMid == Accounts.main.mid) return _request;
      await _request;
      if (isLoading) return _request;
    }
    if (isClosed || _keepPanel) return;
    _feedRefresh = feed;
    return super.onRefresh();
  }

  Future<void> refreshTab(DynamicsTabController? tab) {
    if (_keepPanel) _sortVisiblePanel();
    final feed = tab?.onRefresh();
    return Future.wait([?feed, singleRefresh(feed)]);
  }

  @override
  Future<void> onRefresh() => refreshTab(controller);

  @override
  Future<void> showRefresh() =>
      controller?.refreshKey.currentState?.show() ?? onRefresh();

  @override
  void animateToTop() {
    controller?.animateToTop();
    scrollController.animToTop();
  }

  @override
  void toTopOrRefresh() {
    final ctr = controller;
    if (ctr?.scrollController.hasClients == true) {
      if (ctr!.scrollController.position.pixels == 0) {
        if (scrollController.hasClients &&
            scrollController.position.pixels != 0) {
          scrollController.animToTop();
        }
        EasyThrottle.throttle(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          showRefresh,
        );
      } else {
        animateToTop();
      }
    } else {
      super.toTopOrRefresh();
    }
  }

  @override
  void onClose() {
    tabController.dispose();
    super.onClose();
  }

  @override
  void onChangeAccount(bool isLogin) {
    _publicationTimes.clear();
    _lastReadUp = null;
    _markingRead = {};
    currentMid = hostMid = -1;
    onReload();
  }

  @override
  Future<LoadingState<FollowUpModel>> customGetData() async {
    if (_firstPage) {
      final feed = _feedRefresh;
      _feedRefresh = null;
      final read = _readDuringRefresh = {..._markingRead};
      try {
        final (result, more, _) = await (
          DynamicsHttp.followUp(),
          _useAppUnread ? DynGrpc.upListMore() : Future.value(null),
          feed?.catchError((Object _) {}) ?? Future<void>.value(),
        ).wait;
        if (more != null) {
          result.dataOrNull?.prependUnread(
            more.dataOrNull?.items ?? const [],
            read,
            lastRead: _lastReadUp,
          );
        }
        return result;
      } catch (e) {
        return Error(e.toString());
      } finally {
        _readDuringRefresh = null;
      }
    }
    if (_showAllUp) {
      return DynamicsHttp.followings(
        vmid: Accounts.main.mid,
        pn: _page,
        orderType: 'attention',
        ps: 50,
      );
    } else {
      return DynamicsHttp.dynUpList(_offset);
    }
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isLoading) return _request;
    if (!isRefresh && (_isEnd || !loadingState.value.isSuccess)) {
      return Future.value();
    }
    _requestMid = Accounts.main.mid;
    _firstPage = isRefresh;
    return _request = super.queryData(isRefresh);
  }

  bool _discardResponse(bool isRefresh) =>
      isClosed || _requestMid != Accounts.main.mid || isRefresh && _keepPanel;

  @override
  bool handleError(String? errMsg) => _discardResponse(true);

  @override
  bool customHandleResponse(bool isRefresh, Success<FollowUpModel> response) {
    if (_discardResponse(isRefresh)) return true;
    final res = response.response;

    if (_showAllUp) {
      _page = isRefresh ? 1 : _page + 1;
      _isEnd = !isRefresh && res.upList?.isNotEmpty != true;
    } else {
      _offset = res.offset;
      _isEnd = res.hasMore != true || _offset.isNullOrEmpty;
    }

    if (isRefresh) {
      if (_showAllUp) {
        res.sortUnread(_publicationTimes, lastReadMid: _lastReadUp?.mid);
        _cacheUpList = res.upList?.toSet();
      }
      loadingState.value = response;
    } else if (res.upList case final upList? when upList.isNotEmpty) {
      if (_cacheUpList case final cached?) upList.removeWhere(cached.contains);
      loadingState
        ..value.data.addAllUpList(upList)
        ..refresh();
    }
    return true;
  }
}
