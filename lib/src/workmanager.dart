import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'options.dart';

/// Function that executes your background work.
/// You should return whether the task ran successfully or not.
///
/// [taskName] Returns the value you provided when registering the task.
/// iOS will pass [Workmanager.iOSBackgroundTask] (for background-fetch) or
/// custom task IDs for BGTaskScheduler based tasks.
///
/// The behavior for retries is different on each platform:
/// - Android: return `false` from the this method will reschedule the work
///   based on the policy given in [Workmanager.registerOneOffTask], for example
/// - iOS: The return value is ignored, but if work has failed, you can schedule
///   another attempt using [Workmanager.registerOneOffTask]. This depends on
///   BGTaskScheduler being set up correctly. Please follow the README for
///   instructions.
typedef BackgroundTaskHandler = Future<bool> Function(
    String taskName, Map<String, dynamic>? inputData);

/// Make sure you followed the platform setup steps first before trying to register any task.
/// Android:
/// - Custom Application class
/// iOS:
/// - Enabled the Background Fetch API
///
/// Inside your Dart code
///
/// Initialize the plugin first
///
/// ```
/// @pragma('vm:entry-point')
/// void callbackDispatcher() {
///   Workmanager().executeTask((taskName, inputData) {
///     switch(taskName) {
///       case "":
///         print("Replace this print statement with your code that should be executed in the background here");
///         break;
///     }
///     return Future.value(true);
///   });
/// }
///
/// void main() {
///   Workmanager().initialize(callbackDispatcher);
/// }
/// ```
///
/// You can schedule a specific iOS task using:
/// - `Workmanager.registerOneOffTask()`
/// Please read the documentation on limitations for background processing on iOS.
///
/// You can now schedule Android tasks using:
/// - `Workmanager.registerOneOffTask()` or `Workmanager.registerPeriodicTask()`
///
/// iOS periodic task is automatically scheduled if you setup the plugin properly.
class Workmanager {
  factory Workmanager() => _instance;

  Workmanager._internal(
      MethodChannel backgroundChannel, MethodChannel foregroundChannel)
      : _backgroundChannel = backgroundChannel,
        _foregroundChannel = foregroundChannel;

  static final Workmanager _instance = Workmanager._internal(
      const MethodChannel(
          "be.tramckrijte.workmanager/background_channel_work_manager"),
      const MethodChannel(
          "be.tramckrijte.workmanager/foreground_channel_work_manager"));

  /// Use this constant inside your callbackDispatcher to identify when an iOS Background Fetch occurred.
  ///
  /// ```
  /// @pragma('vm:entry-point')
  /// void callbackDispatcher() {
  ///   Workmanager().executeTask((taskName, inputData) {
  ///      switch (taskName) {
  ///        case Workmanager.iOSBackgroundProcessingTask:
  ///          stderr.writeln("The iOS background fetch was triggered");
  ///          break;
  ///        case Workmanager.iOSBackgroundAppRefresh:
  ///          stderr.writeln("The iOS backgroundAppRefresh was triggered");
  ///           break;
  ///      }
  ///
  ///      return Future.value(true);
  ///  });
  /// }
  /// ```

  static bool _isInDebugMode = false;

  MethodChannel _backgroundChannel = const MethodChannel(
      "be.tramckrijte.workmanager/background_channel_work_manager");
  MethodChannel _foregroundChannel = const MethodChannel(
      "be.tramckrijte.workmanager/foreground_channel_work_manager");

  // TODO remove these and convert to user named tasks, and change above example
  static const BACKGROUND_APPREFRESH_TASK_NAME = "iOSBackgroundAppRefresh";
  static const BACKGROUND_PROCESSING_TASK_NAME = "iOSBackgroundProcessingTask";

  /// A helper function so you only need to implement a [BackgroundTaskHandler]
  void executeTask(final BackgroundTaskHandler backgroundTask) {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    _backgroundChannel.setMethodCallHandler((call) async {
      final inputData = call.arguments["be.tramckrijte.workmanager.INPUT_DATA"];
      return backgroundTask(
        call.arguments["be.tramckrijte.workmanager.DART_TASK"],
        inputData == null ? null : jsonDecode(inputData),
      );
    });
    _backgroundChannel.invokeMethod("backgroundChannelInitialized");
  }

  /// This call is required if you wish to use the [WorkManager] plugin.
  /// [callbackDispatcher] is a top level function which will be invoked by
  /// Android or iOS. See the discussion on [BackgroundTaskHandler] for details.
  /// [isInDebugMode] true will post debug notifications with information about when a task should have run
  Future<void> initialize(
    final Function callbackDispatcher, {
    final bool isInDebugMode = false,
  }) async {
    Workmanager._isInDebugMode = isInDebugMode;
    final callback = PluginUtilities.getCallbackHandle(callbackDispatcher);
    assert(callback != null,
        "The callbackDispatcher needs to be either a static function or a top level function to be accessible as a Flutter entry point.");
    if (callback != null) {
      final int handle = callback.toRawHandle();
      await _foregroundChannel.invokeMethod<void>(
        'initialize',
        JsonMapperHelper.toInitializeMethodArgument(
          isInDebugMode: _isInDebugMode,
          callbackHandle: handle,
        ),
      );
    }
  }

  /// Checks whether user or parental control restricts background refresh.
  /// Only available on iOS.
  Future<BackgroundAuthorisationState>
      checkBackgroundRefreshPermission() async {
    try {
      var result = await _foregroundChannel.invokeMethod<Object>(
        'checkBackgroundRefreshPermission',
        JsonMapperHelper.toInitializeMethodArgument(
          isInDebugMode: _isInDebugMode,
          callbackHandle: 0,
        ),
      );
      switch (result.toString()) {
        case 'available':
          return BackgroundAuthorisationState.available;
        case 'denied':
          return BackgroundAuthorisationState.denied;
        case 'restricted':
          return BackgroundAuthorisationState.restricted;
        case 'unknown':
          return BackgroundAuthorisationState.unknown;
      }
    } catch (e) {
      print("Could not retrieve BackgroundAuthorisationState " + e.toString());
    }
    return BackgroundAuthorisationState.unknown;
  }

  /// Schedule a one off task.
  /// On iOS immediately starts with a timeout of 29 secs in background.
  /// A [uniqueName] is required so only one task can be registered.
  /// The [taskName] is the value that will be returned in the [BackgroundTaskHandler]
  /// The [inputData] is the input data for task. Valid value types are: int, bool, double, String and their list
  Future<void> registerOneOffTask(
    /// Only supported on Android.
    final String uniqueName,

    /// Only supported on Android.
    final String taskName, {
    /// Only supported on Android.
    final String? tag,

    /// Only supported on Android.
    final ExistingWorkPolicy? existingWorkPolicy,

    /// Configures a initial delay.
    ///
    /// The delay configured here is not guaranteed. The underlying system may
    /// decide to schedule the ask a lot later.
    final Duration initialDelay = Duration.zero,

    /// set required [NetworkType] only iOS
    final NetworkType? networkType = NetworkType.not_required,

    ///set if charging is needed
    final bool? requiresCharging = false,

    /// Fully supported on Android, but only partially supported on iOS.
    /// See [Constraints] for details.
    final Constraints? constraints,
    final BackoffPolicy? backoffPolicy,
    final Duration backoffPolicyDelay = Duration.zero,
    final OutOfQuotaPolicy? outOfQuotaPolicy,
    final Map<String, dynamic>? inputData,
  }) async =>
      await _foregroundChannel.invokeMethod(
        "registerOneOffTask",
        JsonMapperHelper.toRegisterMethodArgument(
          isInDebugMode: _isInDebugMode,
          uniqueName: uniqueName,
          taskName: taskName,
          tag: tag,
          existingWorkPolicy: existingWorkPolicy,
          initialDelay: initialDelay,
          constraints: constraints,
          backoffPolicy: backoffPolicy,
          backoffPolicyDelay: backoffPolicyDelay,
          outOfQuotaPolicy: outOfQuotaPolicy,
          networkType: networkType,
          requiresCharging: requiresCharging,
          inputData: inputData,
        ),
      );

  /// Schedule a background long running task, currently only available on iOS.
  ///
  /// Processing tasks are for long processes like data processing and app maintenance.
  /// Processing tasks can run for minutes, but the system can interrupt these.
  /// Processing tasks run only when the device is idle. iOS terminates any
  /// background processing tasks running when the user starts using the device.
  /// However background refresh tasks aren’t affected.
  ///
  ///
  /// See Apple docs https://developer.apple.com/documentation/uikit/app_and_environment/scenes/preparing_your_ui_to_run_in_the_background/using_background_tasks_to_update_your_app
  /// https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask
  Future<void> registerProcessingTask(
    final String uniqueName,
    final String taskName, {
    /// set required [NetworkType] only iOS
    final NetworkType? networkType = NetworkType.not_required,

    ///set if charging is needed
    final bool? requiresCharging = false,

    /// Only partially supported on iOS.
    /// See [Constraints] for details.
    final Constraints? constraints,
    final BackoffPolicy? backoffPolicy,
    final Duration backoffPolicyDelay = Duration.zero,
    final OutOfQuotaPolicy? outOfQuotaPolicy,
    final Map<String, dynamic>? inputData,
  }) async =>
      await _foregroundChannel.invokeMethod(
        "registerProcessingTask",
        JsonMapperHelper.toRegisterMethodArgument(
            isInDebugMode: _isInDebugMode,
            uniqueName: uniqueName,
            taskName: taskName,
            constraints: constraints,
            backoffPolicy: backoffPolicy,
            backoffPolicyDelay: backoffPolicyDelay,
            outOfQuotaPolicy: outOfQuotaPolicy,
            networkType: networkType,
            requiresCharging: requiresCharging),
      );

  /// Schedules a periodic task that will run every provided [frequency], on iOS it is not guaranteed when or how often it will run.
  /// A [uniqueName] is required so only one task can be registered.
  /// The [taskName] is the value that will be returned in the [BackgroundTaskHandler]
  /// a [frequency] is not required and will be defaulted to 15 minutes if not provided.
  /// a [frequency] has a minimum of 15 min. Android will automatically change your frequency to 15 min if you have configured a lower frequency.
  /// The [inputData] is the input data for task. Valid value types are: int, bool, double, String and their list
  Future<void> registerPeriodicTask(
    final String uniqueName,
    final String taskName, {
    final Duration? frequency,
    final String? tag,
    final ExistingWorkPolicy? existingWorkPolicy,
    final Duration initialDelay = Duration.zero,
    final Constraints? constraints,
    final BackoffPolicy? backoffPolicy,
    final Duration backoffPolicyDelay = Duration.zero,
    final OutOfQuotaPolicy? outOfQuotaPolicy,
    final NetworkType? networkType = NetworkType.not_required,
    final bool? requiresCharging = false,
    final Map<String, dynamic>? inputData,
  }) async =>
      await _foregroundChannel.invokeMethod(
        "registerPeriodicTask",
        JsonMapperHelper.toRegisterMethodArgument(
          isInDebugMode: _isInDebugMode,
          uniqueName: uniqueName,
          taskName: taskName,
          frequency: frequency,
          tag: tag,
          existingWorkPolicy: existingWorkPolicy,
          initialDelay: initialDelay,
          constraints: constraints,
          backoffPolicy: backoffPolicy,
          backoffPolicyDelay: backoffPolicyDelay,
          outOfQuotaPolicy: outOfQuotaPolicy,
          networkType: networkType,
          requiresCharging: requiresCharging,
          inputData: inputData,
        ),
      );

  /// Cancels a task by its [uniqueName]
  Future<void> cancelByUniqueName(final String uniqueName) async =>
      await _foregroundChannel.invokeMethod(
        "cancelTaskByUniqueName",
        {"uniqueName": uniqueName},
      );

  /// Cancels a task by its [tag]
  Future<void> cancelByTag(final String tag) async =>
      await _foregroundChannel.invokeMethod(
        "cancelTaskByTag",
        {"tag": tag},
      );

  /// Cancels all tasks
  Future<void> cancelAll() async =>
      await _foregroundChannel.invokeMethod("cancelAllTasks");
}

/// A helper object to convert the selected options to JSON format. Mainly for testability.
class JsonMapperHelper {
  @visibleForTesting
  static Map<String, Object?> toRegisterMethodArgument({
    final bool isInDebugMode = false,
    final String? uniqueName,
    final String? taskName,
    final Duration? frequency,
    final String? tag,
    final ExistingWorkPolicy? existingWorkPolicy,
    final Duration? initialDelay,
    final Constraints? constraints,
    final BackoffPolicy? backoffPolicy,
    final Duration? backoffPolicyDelay,
    final OutOfQuotaPolicy? outOfQuotaPolicy,
    NetworkType? networkType,
    bool? requiresCharging,
    final Map<String, dynamic>? inputData,
  }) {
    if (inputData != null) {
      for (final entry in inputData.entries) {
        final key = entry.key;
        final value = entry.value;
        if (!(value is int ||
            value is bool ||
            value is double ||
            value is String ||
            value is List<int> ||
            value is List<bool> ||
            value is List<double> ||
            value is List<String>)) {
          throw Exception(
              "argument $key has wrong type. WorkManager supports only int, bool, double, String and their list");
        }
      }
    }

    assert(uniqueName != null);
    assert(taskName != null);
    return {
      "isInDebugMode": isInDebugMode,
      "uniqueName": uniqueName,
      "taskName": taskName,
      "tag": tag,
      "frequency": frequency?.inSeconds,
      "existingWorkPolicy": _enumToString(existingWorkPolicy),
      "initialDelaySeconds": initialDelay?.inSeconds,
      "networkType": _enumToString(constraints?.networkType),
      "requiresBatteryNotLow": constraints?.requiresBatteryNotLow,
      "requiresCharging": constraints?.requiresCharging,
      "requiresDeviceIdle": constraints?.requiresDeviceIdle,
      "requiresStorageNotLow": constraints?.requiresStorageNotLow,
      "backoffPolicyType": _enumToString(backoffPolicy),
      "backoffDelayInMilliseconds": backoffPolicyDelay?.inMilliseconds,
      "outOfQuotaPolicy": _enumToString(outOfQuotaPolicy),
      "inputData": inputData == null ? null : jsonEncode(inputData),
    };
  }

  @visibleForTesting
  static Map<String, Object?> toInitializeMethodArgument({
    required final bool isInDebugMode,
    required final int callbackHandle,
  }) {
    return {
      "isInDebugMode": isInDebugMode,
      "callbackHandle": callbackHandle,
    };
  }

  static String? _enumToString(final dynamic enumeration) =>
      enumeration?.toString().split('.').last;
}
