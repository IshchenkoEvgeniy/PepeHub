import 'package:audio_session/audio_session.dart';

/// Keep CAN_DUCK distinguishable from calls/transient exclusive focus loss.
/// Spoken audio is still paused by our handler, then resumed automatically.
final spokenAudioConfiguration = const AudioSessionConfiguration.speech()
    .copyWith(androidWillPauseWhenDucked: false);
