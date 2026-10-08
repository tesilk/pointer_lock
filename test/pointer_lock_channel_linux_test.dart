import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointer_lock/pointer_lock.dart';
import 'package:pointer_lock/src/pointer_lock_channel.dart';
import 'package:pointer_lock/src/pointer_lock_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ChannelPointerLock platform;
  late List<String> calledMethods;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    platform = ChannelPointerLock();
    PointerLockPlatform.instance = platform;
    calledMethods = [];
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(platform.methodChannel, null);
    messenger.setMockStreamHandler(platform.sessionEventChannel, null);
  });

  void answerMethodCalls({required bool isNativeSessionAvailable}) {
    messenger.setMockMethodCallHandler(platform.methodChannel, (call) async {
      calledMethods.add(call.method);
      return switch (call.method) {
        'nativeSessionAvailable' => isNativeSessionAvailable,
        'lastPointerDelta' => <double>[0, 0],
        _ => null,
      };
    });
  }

  test('a native session listens with unlockOnPointerUp and streams the deltas the platform sends', () async {
    answerMethodCalls(isNativeSessionAvailable: true);
    final listenArguments = <Object?>[];
    var isNativeSessionCancelled = false;
    messenger.setMockStreamHandler(
      platform.sessionEventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          listenArguments.add(arguments);
          events.success(Float64List.fromList([3, -4]));
        },
        onCancel: (_) => isNativeSessionCancelled = true,
      ),
    );

    final deltas = <Offset>[];
    final subscription = pointerLock
        .createSession(cursor: PointerLockCursor.normal, unlockOnPointerUp: true)
        .listen((event) => deltas.add(event.delta));
    await pumpEventQueue();

    expect(listenArguments, [true]);
    expect(deltas, [const Offset(3, -4)]);
    await subscription.cancel();
    await pumpEventQueue();
    expect(isNativeSessionCancelled, isTrue);
    expect(calledMethods, ['nativeSessionAvailable']);
  });

  test('without a native session, the Dart-driven stream locks on listen and unlocks on cancel', () async {
    answerMethodCalls(isNativeSessionAvailable: false);
    var isNativeSessionListened = false;
    messenger.setMockStreamHandler(
      platform.sessionEventChannel,
      MockStreamHandler.inline(onListen: (_, __) => isNativeSessionListened = true),
    );

    final subscription = pointerLock.createSession(cursor: PointerLockCursor.normal).listen(null);
    await pumpEventQueue();
    expect(calledMethods, ['nativeSessionAvailable', 'lockPointer']);

    await subscription.cancel();
    await pumpEventQueue();
    expect(calledMethods, ['nativeSessionAvailable', 'lockPointer', 'unlockPointer']);
    expect(isNativeSessionListened, isFalse);
  });

  test('the platform ending the native session ends the session stream', () async {
    answerMethodCalls(isNativeSessionAvailable: true);
    late MockStreamHandlerEventSink nativeSessionEvents;
    messenger.setMockStreamHandler(
      platform.sessionEventChannel,
      MockStreamHandler.inline(onListen: (_, events) => nativeSessionEvents = events),
    );

    var isDone = false;
    pointerLock
        .createSession(cursor: PointerLockCursor.normal, unlockOnPointerUp: true)
        .listen(null, onDone: () => isDone = true);
    await pumpEventQueue();
    expect(isDone, isFalse);

    nativeSessionEvents.endOfStream();
    await pumpEventQueue();
    expect(isDone, isTrue);
  });

  test('a native session that fails to start reports the error and ends', () async {
    answerMethodCalls(isNativeSessionAvailable: true);
    messenger.setMockStreamHandler(
      platform.sessionEventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          events.error(code: 'Native pointer lock failed', message: 'No Wayland surface or pointer to lock');
          events.endOfStream();
        },
      ),
    );

    final errors = <Object>[];
    var isDone = false;
    pointerLock
        .createSession(cursor: PointerLockCursor.normal)
        .listen(null, onError: errors.add, onDone: () => isDone = true);
    await pumpEventQueue();

    expect(errors, [isA<PlatformException>().having((error) => error.code, 'code', 'Native pointer lock failed')]);
    expect(isDone, isTrue);
  });

  test('the native session availability is asked once', () async {
    answerMethodCalls(isNativeSessionAvailable: true);
    var nativeSessionListenCount = 0;
    messenger.setMockStreamHandler(
      platform.sessionEventChannel,
      MockStreamHandler.inline(onListen: (_, __) => nativeSessionListenCount++),
    );

    for (var i = 0; i < 2; i++) {
      final subscription = pointerLock.createSession(cursor: PointerLockCursor.normal).listen(null);
      await pumpEventQueue();
      await subscription.cancel();
      await pumpEventQueue();
    }

    expect(nativeSessionListenCount, 2);
    expect(calledMethods, ['nativeSessionAvailable']);
  });

  test('a session cancelled before the availability answer never locks', () async {
    final availabilityAnswer = Completer<bool>();
    messenger.setMockMethodCallHandler(platform.methodChannel, (call) {
      calledMethods.add(call.method);
      return call.method == 'nativeSessionAvailable' ? availabilityAnswer.future : Future<void>.value();
    });

    final subscription = pointerLock.createSession(cursor: PointerLockCursor.normal).listen(null);
    await pumpEventQueue();
    final cancellation = subscription.cancel();
    availabilityAnswer.complete(false);
    await cancellation;
    await pumpEventQueue();

    expect(calledMethods, ['nativeSessionAvailable']);
  });

  test('ensureInitialized completes on a platform without a native side', () async {
    await expectLater(pointerLock.ensureInitialized(), completes);
  });

  test('without a native side, a session reports one error and ends, and nothing escapes uncaught', () async {
    final errors = <Object>[];
    var isDone = false;
    pointerLock.createSession().listen(null, onError: errors.add, onDone: () => isDone = true);
    await pumpEventQueue();

    expect(errors, [isA<MissingPluginException>()]);
    expect(isDone, isTrue);
  });

  test('a native side without the lock reports one error, and its missing unlock escapes nothing', () async {
    messenger.setMockMethodCallHandler(platform.methodChannel, (call) async {
      calledMethods.add(call.method);
      if (call.method == 'nativeSessionAvailable') {
        return false;
      }
      throw MissingPluginException();
    });

    final errors = <Object>[];
    var isDone = false;
    pointerLock
        .createSession(cursor: PointerLockCursor.normal)
        .listen(null, onError: errors.add, onDone: () => isDone = true);
    await pumpEventQueue();

    expect(errors, [isA<MissingPluginException>()]);
    expect(isDone, isTrue);
    expect(calledMethods, ['nativeSessionAvailable', 'lockPointer', 'unlockPointer']);
  });

  test('a failed lock reports the error, ends the session and leaves the pointer packet callback alone', () async {
    final lockAnswer = Completer<void>();
    messenger.setMockMethodCallHandler(platform.methodChannel, (call) {
      calledMethods.add(call.method);
      return switch (call.method) {
        'nativeSessionAvailable' => Future.value(false),
        'lockPointer' => lockAnswer.future,
        _ => Future<void>.value(),
      };
    });
    final callbackBeforeSession = PlatformDispatcher.instance.onPointerDataPacket;
    addTearDown(() => PlatformDispatcher.instance.onPointerDataPacket = callbackBeforeSession);

    final errors = <Object>[];
    var isDone = false;
    pointerLock
        .createSession(cursor: PointerLockCursor.normal)
        .listen(null, onError: errors.add, onDone: () => isDone = true);
    await pumpEventQueue();
    void callbackSetMeanwhile(PointerDataPacket packet) {}
    PlatformDispatcher.instance.onPointerDataPacket = callbackSetMeanwhile;
    lockAnswer.completeError(PlatformException(code: 'gdk_seat_grab failed'));
    await pumpEventQueue();

    expect(errors, [isA<PlatformException>()]);
    expect(isDone, isTrue);
    expect(PlatformDispatcher.instance.onPointerDataPacket, same(callbackSetMeanwhile));
  });

  test('a session cancelled while hiding the pointer never locks', () async {
    final hideAnswer = Completer<void>();
    messenger.setMockMethodCallHandler(platform.methodChannel, (call) {
      calledMethods.add(call.method);
      return switch (call.method) {
        'hidePointer' => hideAnswer.future,
        'nativeSessionAvailable' => Future.value(false),
        _ => Future<void>.value(),
      };
    });

    final subscription = pointerLock.createSession().listen(null);
    await pumpEventQueue();
    await subscription.cancel();
    hideAnswer.complete();
    await pumpEventQueue();

    expect(calledMethods, ['hidePointer', 'showPointer']);
  });

  test('a session cancelled while locking never hooks the pointer packets', () async {
    final lockAnswer = Completer<void>();
    messenger.setMockMethodCallHandler(platform.methodChannel, (call) {
      calledMethods.add(call.method);
      return switch (call.method) {
        'nativeSessionAvailable' => Future.value(false),
        'lockPointer' => lockAnswer.future,
        _ => Future<void>.value(),
      };
    });
    final callbackBeforeSession = PlatformDispatcher.instance.onPointerDataPacket;

    final subscription = pointerLock.createSession(cursor: PointerLockCursor.normal).listen(null);
    await pumpEventQueue();
    await subscription.cancel();
    lockAnswer.complete();
    await pumpEventQueue();

    expect(PlatformDispatcher.instance.onPointerDataPacket, same(callbackBeforeSession));
    expect(calledMethods, ['nativeSessionAvailable', 'lockPointer', 'unlockPointer']);
  });
}
