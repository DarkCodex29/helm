// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'project_shortcut.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

ProjectShortcut _$ProjectShortcutFromJson(Map<String, dynamic> json) {
  return _ProjectShortcut.fromJson(json);
}

/// @nodoc
mixin _$ProjectShortcut {
  /// Unique identifier (UUID v4).
  String get id => throw _privateConstructorUsedError;

  /// Human-readable name (e.g. "Metalpren").
  String get name => throw _privateConstructorUsedError;

  /// Absolute path on the remote machine (e.g. "/home/gian/proyectos/metalpren").
  String get projectPath => throw _privateConstructorUsedError;

  /// tmux session name to attach to or create (e.g. "metalpren").
  /// Superseded by [sessionRef] — see the class doc.
  String get tmuxSession => throw _privateConstructorUsedError;

  /// Command to run after navigating to [projectPath] (e.g. "opencode").
  /// Empty string means no command is run.
  String get command => throw _privateConstructorUsedError;

  /// ID of the [ConnectionProfile] to use.
  String get profileId => throw _privateConstructorUsedError;

  /// Sort order for display in the sidebar.
  int get sortOrder => throw _privateConstructorUsedError;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback; callers apply AppConstants.defaultSessionRef themselves,
  /// exactly as they already did for [tmuxSession] before this
  /// migration. `invalid_annotation_target` (see the file-level ignore
  /// above) is a known freezed+json_serializable false positive for
  /// this exact pattern.
  @JsonKey(readValue: _readSessionRef)
  String? get sessionRef => throw _privateConstructorUsedError;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see `MultiplexerId` in
  /// `lib/core/host/multiplexer_adapter.dart`).
  String? get multiplexer => throw _privateConstructorUsedError;

  /// Serializes this ProjectShortcut to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ProjectShortcut
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ProjectShortcutCopyWith<ProjectShortcut> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ProjectShortcutCopyWith<$Res> {
  factory $ProjectShortcutCopyWith(
    ProjectShortcut value,
    $Res Function(ProjectShortcut) then,
  ) = _$ProjectShortcutCopyWithImpl<$Res, ProjectShortcut>;
  @useResult
  $Res call({
    String id,
    String name,
    String projectPath,
    String tmuxSession,
    String command,
    String profileId,
    int sortOrder,
    @JsonKey(readValue: _readSessionRef) String? sessionRef,
    String? multiplexer,
  });
}

/// @nodoc
class _$ProjectShortcutCopyWithImpl<$Res, $Val extends ProjectShortcut>
    implements $ProjectShortcutCopyWith<$Res> {
  _$ProjectShortcutCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ProjectShortcut
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? name = null,
    Object? projectPath = null,
    Object? tmuxSession = null,
    Object? command = null,
    Object? profileId = null,
    Object? sortOrder = null,
    Object? sessionRef = freezed,
    Object? multiplexer = freezed,
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
            projectPath: null == projectPath
                ? _value.projectPath
                : projectPath // ignore: cast_nullable_to_non_nullable
                      as String,
            tmuxSession: null == tmuxSession
                ? _value.tmuxSession
                : tmuxSession // ignore: cast_nullable_to_non_nullable
                      as String,
            command: null == command
                ? _value.command
                : command // ignore: cast_nullable_to_non_nullable
                      as String,
            profileId: null == profileId
                ? _value.profileId
                : profileId // ignore: cast_nullable_to_non_nullable
                      as String,
            sortOrder: null == sortOrder
                ? _value.sortOrder
                : sortOrder // ignore: cast_nullable_to_non_nullable
                      as int,
            sessionRef: freezed == sessionRef
                ? _value.sessionRef
                : sessionRef // ignore: cast_nullable_to_non_nullable
                      as String?,
            multiplexer: freezed == multiplexer
                ? _value.multiplexer
                : multiplexer // ignore: cast_nullable_to_non_nullable
                      as String?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ProjectShortcutImplCopyWith<$Res>
    implements $ProjectShortcutCopyWith<$Res> {
  factory _$$ProjectShortcutImplCopyWith(
    _$ProjectShortcutImpl value,
    $Res Function(_$ProjectShortcutImpl) then,
  ) = __$$ProjectShortcutImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String id,
    String name,
    String projectPath,
    String tmuxSession,
    String command,
    String profileId,
    int sortOrder,
    @JsonKey(readValue: _readSessionRef) String? sessionRef,
    String? multiplexer,
  });
}

/// @nodoc
class __$$ProjectShortcutImplCopyWithImpl<$Res>
    extends _$ProjectShortcutCopyWithImpl<$Res, _$ProjectShortcutImpl>
    implements _$$ProjectShortcutImplCopyWith<$Res> {
  __$$ProjectShortcutImplCopyWithImpl(
    _$ProjectShortcutImpl _value,
    $Res Function(_$ProjectShortcutImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ProjectShortcut
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? name = null,
    Object? projectPath = null,
    Object? tmuxSession = null,
    Object? command = null,
    Object? profileId = null,
    Object? sortOrder = null,
    Object? sessionRef = freezed,
    Object? multiplexer = freezed,
  }) {
    return _then(
      _$ProjectShortcutImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as String,
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        projectPath: null == projectPath
            ? _value.projectPath
            : projectPath // ignore: cast_nullable_to_non_nullable
                  as String,
        tmuxSession: null == tmuxSession
            ? _value.tmuxSession
            : tmuxSession // ignore: cast_nullable_to_non_nullable
                  as String,
        command: null == command
            ? _value.command
            : command // ignore: cast_nullable_to_non_nullable
                  as String,
        profileId: null == profileId
            ? _value.profileId
            : profileId // ignore: cast_nullable_to_non_nullable
                  as String,
        sortOrder: null == sortOrder
            ? _value.sortOrder
            : sortOrder // ignore: cast_nullable_to_non_nullable
                  as int,
        sessionRef: freezed == sessionRef
            ? _value.sessionRef
            : sessionRef // ignore: cast_nullable_to_non_nullable
                  as String?,
        multiplexer: freezed == multiplexer
            ? _value.multiplexer
            : multiplexer // ignore: cast_nullable_to_non_nullable
                  as String?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$ProjectShortcutImpl implements _ProjectShortcut {
  const _$ProjectShortcutImpl({
    required this.id,
    required this.name,
    required this.projectPath,
    required this.tmuxSession,
    this.command = '',
    required this.profileId,
    this.sortOrder = 0,
    @JsonKey(readValue: _readSessionRef) this.sessionRef,
    this.multiplexer,
  });

  factory _$ProjectShortcutImpl.fromJson(Map<String, dynamic> json) =>
      _$$ProjectShortcutImplFromJson(json);

  /// Unique identifier (UUID v4).
  @override
  final String id;

  /// Human-readable name (e.g. "Metalpren").
  @override
  final String name;

  /// Absolute path on the remote machine (e.g. "/home/gian/proyectos/metalpren").
  @override
  final String projectPath;

  /// tmux session name to attach to or create (e.g. "metalpren").
  /// Superseded by [sessionRef] — see the class doc.
  @override
  final String tmuxSession;

  /// Command to run after navigating to [projectPath] (e.g. "opencode").
  /// Empty string means no command is run.
  @override
  @JsonKey()
  final String command;

  /// ID of the [ConnectionProfile] to use.
  @override
  final String profileId;

  /// Sort order for display in the sidebar.
  @override
  @JsonKey()
  final int sortOrder;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback; callers apply AppConstants.defaultSessionRef themselves,
  /// exactly as they already did for [tmuxSession] before this
  /// migration. `invalid_annotation_target` (see the file-level ignore
  /// above) is a known freezed+json_serializable false positive for
  /// this exact pattern.
  @override
  @JsonKey(readValue: _readSessionRef)
  final String? sessionRef;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see `MultiplexerId` in
  /// `lib/core/host/multiplexer_adapter.dart`).
  @override
  final String? multiplexer;

  @override
  String toString() {
    return 'ProjectShortcut(id: $id, name: $name, projectPath: $projectPath, tmuxSession: $tmuxSession, command: $command, profileId: $profileId, sortOrder: $sortOrder, sessionRef: $sessionRef, multiplexer: $multiplexer)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ProjectShortcutImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.projectPath, projectPath) ||
                other.projectPath == projectPath) &&
            (identical(other.tmuxSession, tmuxSession) ||
                other.tmuxSession == tmuxSession) &&
            (identical(other.command, command) || other.command == command) &&
            (identical(other.profileId, profileId) ||
                other.profileId == profileId) &&
            (identical(other.sortOrder, sortOrder) ||
                other.sortOrder == sortOrder) &&
            (identical(other.sessionRef, sessionRef) ||
                other.sessionRef == sessionRef) &&
            (identical(other.multiplexer, multiplexer) ||
                other.multiplexer == multiplexer));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    name,
    projectPath,
    tmuxSession,
    command,
    profileId,
    sortOrder,
    sessionRef,
    multiplexer,
  );

  /// Create a copy of ProjectShortcut
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ProjectShortcutImplCopyWith<_$ProjectShortcutImpl> get copyWith =>
      __$$ProjectShortcutImplCopyWithImpl<_$ProjectShortcutImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$ProjectShortcutImplToJson(this);
  }
}

abstract class _ProjectShortcut implements ProjectShortcut {
  const factory _ProjectShortcut({
    required final String id,
    required final String name,
    required final String projectPath,
    required final String tmuxSession,
    final String command,
    required final String profileId,
    final int sortOrder,
    @JsonKey(readValue: _readSessionRef) final String? sessionRef,
    final String? multiplexer,
  }) = _$ProjectShortcutImpl;

  factory _ProjectShortcut.fromJson(Map<String, dynamic> json) =
      _$ProjectShortcutImpl.fromJson;

  /// Unique identifier (UUID v4).
  @override
  String get id;

  /// Human-readable name (e.g. "Metalpren").
  @override
  String get name;

  /// Absolute path on the remote machine (e.g. "/home/gian/proyectos/metalpren").
  @override
  String get projectPath;

  /// tmux session name to attach to or create (e.g. "metalpren").
  /// Superseded by [sessionRef] — see the class doc.
  @override
  String get tmuxSession;

  /// Command to run after navigating to [projectPath] (e.g. "opencode").
  /// Empty string means no command is run.
  @override
  String get command;

  /// ID of the [ConnectionProfile] to use.
  @override
  String get profileId;

  /// Sort order for display in the sidebar.
  @override
  int get sortOrder;

  /// Neutral session reference, meaningful for whichever [multiplexer]
  /// is selected. See [_readSessionRef] for the read-time precedence
  /// rule. Never defaulted here — a null value is not an invented
  /// fallback; callers apply AppConstants.defaultSessionRef themselves,
  /// exactly as they already did for [tmuxSession] before this
  /// migration. `invalid_annotation_target` (see the file-level ignore
  /// above) is a known freezed+json_serializable false positive for
  /// this exact pattern.
  @override
  @JsonKey(readValue: _readSessionRef)
  String? get sessionRef;

  /// Which multiplexer [sessionRef] applies to. `null` means the host's
  /// default multiplexer (see `MultiplexerId` in
  /// `lib/core/host/multiplexer_adapter.dart`).
  @override
  String? get multiplexer;

  /// Create a copy of ProjectShortcut
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ProjectShortcutImplCopyWith<_$ProjectShortcutImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
