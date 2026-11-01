import 'dart:async';

import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/pages/dynamics_tab/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/dynamic_up_tracker.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:get/get.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart' show TabController;

class DynamicsController
    extends CommonDataController<FollowUpModel, FollowUpModel>
    with GetSingleTickerProviderStateMixin, AccountMixin {
  late final TabController tabController;

  final Set<int> tempBannedList = <int>{};

  String? _offset;
  late int _page = 1;
  late bool _isEnd = false;
  DynamicUpTracker? _tracker;
  Account? _requestAccount;
  int _generation = 0, _requestGeneration = 0;
  bool _refreshPending = false;
  Future<void>? _loadTask;

  late int hostMid = -1, currentMid = -1;
  late bool showLiveUp = Pref.expandDynLivePanel;
  late final _showAllUp = Pref.dynamicsShowAllFollowedUp;

  final upPanelPosition = Pref.upPanelPosition;

  @override
  final AccountService accountService = Get.find<AccountService>();

  bool get _isCurrentResponse =>
      !isClosed &&
      _requestGeneration == _generation &&
      identical(_requestAccount, Accounts.main);

  DynamicUpTracker? get _updates {
    final account = Accounts.main;
    if (!_showAllUp || !account.isLogin) return null;
    if (_tracker?.isCurrent != true) {
      _tracker?.dispose();
      _tracker = DynamicUpTracker(
        account,
        onChanged: () {
          if (loadingState.value case Success(:final response)) {
            _tracker!.state.apply(response);
            loadingState.refresh();
          }
        },
        onError: () => SmartDialog.showToast('部分 UP 更新检查失败，下拉刷新可重试'),
      );
    }
    return _tracker;
  }

  void markUpRead(UpItem item) {
    item.hasUpdate = false;
    final tracker = _updates;
    if (tracker == null) return;
    tracker.markRead(item.mid);
    if (loadingState.value case Success(:final response)) {
      tracker.state.apply(response, sort: false);
      loadingState.refresh();
    }
  }

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

  void onSelectUp(int mid) {
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
  }

  Future<void> singleRefresh() {
    if (isLoading) {
      _refreshPending = true;
      return _loadTask ?? Future.value();
    }
    _resetPagination();
    return super.onRefresh();
  }

  void _resetPagination() {
    _page = 1;
    _offset = null;
    _isEnd = false;
  }

  @override
  Future<void> onRefresh() async {
    final controller = this.controller;
    await Future.wait([
      singleRefresh(),
      if (controller != null) controller.onRefresh(),
    ]);
  }

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
          onRefresh,
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
    _generation++;
    _tracker?.dispose();
    tabController.dispose();
    super.onClose();
  }

  @override
  void onChangeAccount(bool isLogin) {
    _generation++;
    _tracker?.dispose();
    _tracker = null;
    currentMid = hostMid = -1;
    onReload();
  }

  @override
  Future<LoadingState<FollowUpModel>> customGetData() async {
    final account = _requestAccount = Accounts.main;
    _requestGeneration = _generation;
    final tracker = _updates;
    try {
      final LoadingState<FollowUpModel> result;
      if (_offset == null) {
        await tracker?.refresh();
        if (!_isCurrentResponse) return const Error('账号已切换');
        result = await DynamicsHttp.followUp(
          loadAll: _showAllUp,
          account: account,
        );
      } else if (_showAllUp) {
        result = await DynamicsHttp.followings(
          vmid: account.mid,
          account: account,
          pn: _page,
          orderType: 'attention',
          ps: 50,
        );
      } else {
        result = await DynamicsHttp.dynUpList(_offset, account: account);
      }
      return _isCurrentResponse ? result : const Error('账号已切换');
    } catch (_) {
      return const Error('动态 UP 列表加载失败，请刷新重试');
    }
  }

  @override
  bool handleError(String? errMsg) => !_isCurrentResponse;

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isClosed || !isRefresh && _isEnd) return Future.value();
    return _loadTask ??= _queryData(isRefresh)
        .whenComplete(() => _loadTask = null);
  }

  Future<void> _queryData(bool isRefresh) async {
    // Keep the base loading/error handling; only coalesce refreshes while busy.
    do {
      try {
        await super.queryData(isRefresh);
      } finally {
        isLoading = false;
      }
      if (!_refreshPending || isClosed) return;
      _refreshPending = false;
      _resetPagination();
      isRefresh = true;
    } while (!isClosed);
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<FollowUpModel> response) {
    if (!_isCurrentResponse) return true;
    final res = response.response;
    final tracker = _updates;
    if (isRefresh) tracker?.state.applyOfficial(res.upList ?? []);

    if (_showAllUp) {
      if (!isRefresh && res.upList?.isNotEmpty != true) {
        _isEnd = true;
      }
    } else {
      _offset = res.offset;
      if (res.hasMore != true || _offset.isNullOrEmpty) {
        _isEnd = true;
      }
    }

    if (isRefresh) {
      if (_showAllUp) {
        _offset = '';
      }
      loadingState.value = response;
    } else {
      if (_showAllUp) {
        _page++;
      }

      if (res.upList case final upList? when upList.isNotEmpty) {
        loadingState
          ..value.data.addAllUpList(upList)
          ..refresh();
      }
    }

    if (tracker != null) {
      tracker.state.apply(loadingState.value.data);
      loadingState.refresh();
    }
    return true;
  }
}
