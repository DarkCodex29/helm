// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'connection_profile.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

ConnectionProfile _$ConnectionProfileFromJson(Map<String, dynamic> json) {
  return _ConnectionProfile.fromJson(json);
}

/// @nodoc
mixin _$ConnectionProfile {
  /// Unique identifier (UUID v4).
  String get id => throw _privateConstructorUsedError;

  /// Human-readable name for this profile (e.g. "Mac Studio").
  String get name => throw _privateConstructorUsedError;

  /// Hostname or IP address of the remote machine.
  String get host => throw _privateConstructorUsedError;

  /// SSH port — defaults to 22.
  int get port => throw _privateConstructorUsedError;

  /// SSH username on the remote machine.
  String get username => throw _privateConstructorUsedError;

  /// Optional custom tmux session name. Falls back to AppConstants.defaultTmuxSession.
  /// Superseded by [sessionRef] — see the class doc.
  String? get tmuxSession => throw _privateConstructorUsedError;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback; callers apply AppConstants.defaultTmuxSession themselves,
  /// exactly as they already did for [tmuxSession] before this
  /// migration. `invalid_annotation_target` (see the file-level ignore
  /// above) is a known freezed+json_serializable false positive for
  /// this exact pattern; the annotation is correctly applied to the
  /// generated field (confirmed: `connection_profile.g.dart` calls
  /// `_readSessionRef(json, 'sessionRef')`).
  @JsonKey(readValue: _readSessionRef)
  String? get sessionRef => throw _privateConstructorUsedError;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see [MultiplexerId] in
  /// `lib/core/host/multiplexer_adapter.dart`).
  String? get multiplexer => throw _privateConstructorUsedError;

  /// Whether this is the default profile to connect to on launch.
  bool get isDefault => throw _privateConstructorUsedError;

  /// Serializes this ConnectionProfile to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ConnectionProfile
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ConnectionProfileCopyWith<ConnectionProfile> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ConnectionProfileCopyWith<$Res> {
  factory $ConnectionProfileCopyWith(
    ConnectionProfile value,
    $Res Function(ConnectionProfile) then,
  ) = _$ConnectionProfileCopyWithImpl<$Res, ConnectionProfile>;
  @useResult
  $Res call({
    String id,
    String name,
    String host,
    int port,
    String username,
    String? tmuxSession,
    @JsonKey(readValue: _readSessionRef) String? sessionRef,
    String? multiplexer,
    bool isDefault,
  });
}

/// @nodoc
class _$ConnectionProfileCopyWithImpl<$Res, $Val extends ConnectionProfile>
    implements $ConnectionProfileCopyWith<$Res> {
  _$ConnectionProfileCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ConnectionProfile
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? name = null,
    Object? host = null,
    Object? port = null,
    Object? username = null,
    Object? tmuxSession = freezed,
    Object? sessionRef = freezed,
    Object? multiplexer = freezed,
    Object? isDefault = null,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as String,
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            host: null == host
                ? _value.host
                : host // ignore: cast_nullable_to_non_nullable
                      as String,
            port: null == port
                ? _value.port
                : port // ignore: cast_nullable_to_non_nullable
                      as int,
            username: null == username
                ? _value.username
                : username // ignore: cast_nullable_to_non_nullable
                      as String,
            tmuxSession: freezed == tmuxSession
                ? _value.tmuxSession
                : tmuxSession // ignore: cast_nullable_to_non_nullable
                      as String?,
            sessionRef: freezed == sessionRef
                ? _value.sessionRef
                : sessionRef // ignore: cast_nullable_to_non_nullable
                      as String?,
            multiplexer: freezed == multiplexer
                ? _value.multiplexer
                : multiplexer // ignore: cast_nullable_to_non_nullable
                      as String?,
            isDefault: null == isDefault
                ? _value.isDefault
                : isDefault // ignore: cast_nullable_to_non_nullable
                      as bool,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ConnectionProfileImplCopyWith<$Res>
    implements $ConnectionProfileCopyWith<$Res> {
  factory _$$ConnectionProfileImplCopyWith(
    _$ConnectionProfileImpl value,
    $Res Function(_$ConnectionProfileImpl) then,
  ) = __$$ConnectionProfileImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String id,
    String name,
    String host,
    int port,
    String username,
    String? tmuxSession,
    @JsonKey(readValue: _readSessionRef) String? sessionRef,
    String? multiplexer,
    bool isDefault,
  });
}

/// @nodoc
class __$$ConnectionProfileImplCopyWithImpl<$Res>
    extends _$ConnectionProfileCopyWithImpl<$Res, _$ConnectionProfileImpl>
    implements _$$ConnectionProfileImplCopyWith<$Res> {
  __$$ConnectionProfileImplCopyWithImpl(
    _$ConnectionProfileImpl _value,
    $Res Function(_$ConnectionProfileImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ConnectionProfile
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? name = null,
    Object? host = null,
    Object? port = null,
    Object? username = null,
    Object? tmuxSession = freezed,
    Object? sessionRef = freezed,
    Object? multiplexer = freezed,
    Object? isDefault = null,
  }) {
    return _then(
      _$ConnectionProfileImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String,
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        host: null == host
            ? _value.host
            : host // ignore: cast_nullable_to_non_nullable
                  as String,
        port: null == port
            ? _value.port
            : port // ignore: cast_nullable_to_non_nullable
                  as int,
        username: null == username
            ? _value.username
            : username // ignore: cast_nullable_to_non_nullable
                  as String,
        tmuxSession: freezed == tmuxSession
            ? _value.tmuxSession
            : tmuxSession // ignore: cast_nullable_to_non_nullable
                  as String?,
        sessionRef: freezed == sessionRef
            ? _value.sessionRef
            : sessionRef // ignore: cast_nullable_to_non_nullable
                  as String?,
        multiplexer: freezed == multiplexer
            ? _value.multiplexer
            : multiplexer // ignore: cast_nullable_to_non_nullable
                  as String?,
        isDefault: null == isDefault
            ? _value.isDefault
            : isDefault // ignore: cast_nullable_to_non_nullable
                  as bool,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ConnectionProfileImpl implements _ConnectionProfile {
  const _$ConnectionProfileImpl({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.tmuxSession,
    @JsonKey(readValue: _readSessionRef) this.sessionRef,
    this.multiplexer,
    this.isDefault = false,
  });

  factory _$ConnectionProfileImpl.fromJson(Map<String, dynamic> json) =>
      _$$ConnectionProfileImplFromJson(json);

  /// Unique identifier (UUID v4).
  @override
  final String id;

  /// Human-readable name for this profile (e.g. "Mac Studio").
  @override
  final String name;

  /// Hostname or IP address of the remote machine.
  @override
  final String host;

  /// SSH port — defaults to 22.
  @override
  @JsonKey()
  final int port;

  /// SSH username on the remote machine.
  @override
  final String username;

  /// Optional custom tmux session name. Falls back to AppConstants.defaultTmuxSession.
  /// Superseded by [sessionRef] — see the class doc.
  @override
  final String? tmuxSession;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback; callers apply AppConstants.defaultTmuxSession themselves,
  /// exactly as they already did for [tmuxSession] before this
  /// migration. `invalid_annotation_target` (see the file-level ignore
  /// above) is a known freezed+json_serializable false positive for
  /// this exact pattern; the annotation is correctly applied to the
  /// generated field (confirmed: `connection_profile.g.dart` calls
  /// `_readSessionRef(json, 'sessionRef')`).
  @override
  @JsonKey(readValue: _readSessionRef)
  final String? sessionRef;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see [MultiplexerId] in
  /// `lib/core/host/multiplexer_adapter.dart`).
  @override
  final String? multiplexer;

  /// Whether this is the default profile to connect to on launch.
  @override
  @JsonKey()
  final bool isDefault;

  @override
  String toString() {
    return 'ConnectionProfile(id: $id, name: $name, host: $host, port: $port, username: $username, tmuxSession: $tmuxSession, sessionRef: $sessionRef, multiplexer: $multiplexer, isDefault: $isDefault)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ConnectionProfileImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.host, host) || other.host == host) &&
            (identical(other.port, port) || other.port == port) &&
            (identical(other.username, username) ||
                other.username == username) &&
            (identical(other.tmuxSession, tmuxSession) ||
                other.tmuxSession == tmuxSession) &&
            (identical(other.sessionRef, sessionRef) ||
                other.sessionRef == sessionRef) &&
            (identical(other.multiplexer, multiplexer) ||
                other.multiplexer == multiplexer) &&
            (identical(other.isDefault, isDefault) ||
                other.isDefault == isDefault));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    name,
    host,
    port,
    username,
    tmuxSession,
    sessionRef,
    multiplexer,
    isDefault,
  );

  /// Create a copy of ConnectionProfile
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ConnectionProfileImplCopyWith<_$ConnectionProfileImpl> get copyWith =>
      __$$ConnectionProfileImplCopyWithImpl<_$ConnectionProfileImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$ConnectionProfileImplToJson(this);
  }
}

abstract class _ConnectionProfile implements ConnectionProfile {
  const factory _ConnectionProfile({
    required final String id,
    required final String name,
    required final String host,
    final int port,
    required final String username,
    final String? tmuxSession,
    @JsonKey(readValue: _readSessionRef) final String? sessionRef,
    final String? multiplexer,
    final bool isDefault,
  }) = _$ConnectionProfileImpl;

  factory _ConnectionProfile.fromJson(Map<String, dynamic> json) =
      _$ConnectionProfileImpl.fromJson;

  /// Unique identifier (UUID v4).
  @override
  String get id;

  /// Human-readable name for this profile (e.g. "Mac Studio").
  @override
  String get name;

  /// Hostname or IP address of the remote machine.
  @override
  String get host;

  /// SSH port — defaults to 22.
  @override
  int get port;

  /// SSH username on the remote machine.
  @override
  String get username;

  /// Optional custom tmux session name. Falls back to AppConstants.defaultTmuxSession.
  /// Superseded by [sessionRef] — see the class doc.
  @override
  String? get tmuxSession;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback; callers apply AppConstants.defaultTmuxSession themselves,
  /// exactly as they already did for [tmuxSession] before this
  /// migration. `invalid_annotation_target` (see the file-level ignore
  /// above) is a known freezed+json_serializable false positive for
  /// this exact pattern; the annotation is correctly applied to the
  /// generated field (confirmed: `connection_profile.g.dart` calls
  /// `_readSessionRef(json, 'sessionRef')`).
  @override
  @JsonKey(readValue: _readSessionRef)
  String? get sessionRef;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see [MultiplexerId] in
  /// `lib/core/host/multiplexer_adapter.dart`).
  @override
  String? get multiplexer;

  /// Whether this is the default profile to connect to on launch.
  @override
  bool get isDefault;

  /// Create a copy of ConnectionProfile
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ConnectionProfileImplCopyWith<_$ConnectionProfileImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
