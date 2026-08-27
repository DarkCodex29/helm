// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'remote_entry.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$RemoteEntry {
  /// The entry's own name, with no path in it.
  String get name => throw _privateConstructorUsedError;

  /// The absolute path of this entry on the remote host.
  String get path => throw _privateConstructorUsedError;
  RemoteEntryKind get kind => throw _privateConstructorUsedError;

  /// For a [RemoteEntryKind.symlink], what the link resolves to.
  ///
  /// Null means "not a symlink, or the target could not be resolved" —
  /// a broken link, or one pointing somewhere the session may not stat.
  /// It is NOT a claim that the target is a file.
  RemoteEntryKind? get linkTarget => throw _privateConstructorUsedError;

  /// Size in bytes, or null when the server omitted it.
  ///
  /// Nullable rather than zero-defaulted: every field of
  /// `SftpFileAttrs` is optional in the protocol
  /// (`sftp_file_attrs.dart:157-187`), and a real zero-byte file must
  /// stay distinguishable from a server that simply did not say.
  int? get size => throw _privateConstructorUsedError;

  /// Last modification time, or null when the server omitted it.
  DateTime? get modifiedAt => throw _privateConstructorUsedError;

  /// Whether this entry is readable — with null meaning "the server did
  /// not give us enough to answer".
  ///
  /// Three-valued ON PURPOSE, and this is the field most likely to look
  /// like an oversight. SFTP reports permission BITS but not whether the
  /// authenticated user owns the file: the `uid`/`gid` in
  /// `SftpFileAttrs` are the FILE's, and the protocol never sends the
  /// session's own. So a mode of `0600` is genuinely unanswerable — it
  /// is readable if we are the owner and refused if we are not, and
  /// nothing on the wire says which.
  ///
  /// Only the two ownership-independent cases are ever asserted: every
  /// read bit set (true), or none set (false). A bool would have forced
  /// one of those guesses onto the middle case, and this codebase does
  /// not represent "unknown" as a definite answer — see
  /// [HostReportStatus.truncated], which exists for the same reason.
  bool? get isReadable => throw _privateConstructorUsedError;

  /// Create a copy of RemoteEntry
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $RemoteEntryCopyWith<RemoteEntry> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $RemoteEntryCopyWith<$Res> {
  factory $RemoteEntryCopyWith(
    RemoteEntry value,
    $Res Function(RemoteEntry) then,
  ) = _$RemoteEntryCopyWithImpl<$Res, RemoteEntry>;
  @useResult
  $Res call({
    String name,
    String path,
    RemoteEntryKind kind,
    RemoteEntryKind? linkTarget,
    int? size,
    DateTime? modifiedAt,
    bool? isReadable,
  });
}

/// @nodoc
class _$RemoteEntryCopyWithImpl<$Res, $Val extends RemoteEntry>
    implements $RemoteEntryCopyWith<$Res> {
  _$RemoteEntryCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of RemoteEntry
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? name = null,
    Object? path = null,
    Object? kind = null,
    Object? linkTarget = freezed,
    Object? size = freezed,
    Object? modifiedAt = freezed,
    Object? isReadable = freezed,
  }) {
    return _then(
      _value.copyWith(
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            path: null == path
                ? _value.path
                : path // ignore: cast_nullable_to_non_nullable
                      as String,
            kind: null == kind
                ? _value.kind
                : kind // ignore: cast_nullable_to_non_nullable
                      as RemoteEntryKind,
            linkTarget: freezed == linkTarget
                ? _value.linkTarget
                : linkTarget // ignore: cast_nullable_to_non_nullable
                      as RemoteEntryKind?,
            size: freezed == size
                ? _value.size
                : size // ignore: cast_nullable_to_non_nullable
                      as int?,
            modifiedAt: freezed == modifiedAt
                ? _value.modifiedAt
                : modifiedAt // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
            isReadable: freezed == isReadable
                ? _value.isReadable
                : isReadable // ignore: cast_nullable_to_non_nullable
                      as bool?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$RemoteEntryImplCopyWith<$Res>
    implements $RemoteEntryCopyWith<$Res> {
  factory _$$RemoteEntryImplCopyWith(
    _$RemoteEntryImpl value,
    $Res Function(_$RemoteEntryImpl) then,
  ) = __$$RemoteEntryImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String name,
    String path,
    RemoteEntryKind kind,
    RemoteEntryKind? linkTarget,
    int? size,
    DateTime? modifiedAt,
    bool? isReadable,
  });
}

/// @nodoc
class __$$RemoteEntryImplCopyWithImpl<$Res>
    extends _$RemoteEntryCopyWithImpl<$Res, _$RemoteEntryImpl>
    implements _$$RemoteEntryImplCopyWith<$Res> {
  __$$RemoteEntryImplCopyWithImpl(
    _$RemoteEntryImpl _value,
    $Res Function(_$RemoteEntryImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of RemoteEntry
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? name = null,
    Object? path = null,
    Object? kind = null,
    Object? linkTarget = freezed,
    Object? size = freezed,
    Object? modifiedAt = freezed,
    Object? isReadable = freezed,
  }) {
    return _then(
      _$RemoteEntryImpl(
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        path: null == path
            ? _value.path
            : path // ignore: cast_nullable_to_non_nullable
                  as String,
        kind: null == kind
            ? _value.kind
            : kind // ignore: cast_nullable_to_non_nullable
                  as RemoteEntryKind,
        linkTarget: freezed == linkTarget
            ? _value.linkTarget
            : linkTarget // ignore: cast_nullable_to_non_nullable
                  as RemoteEntryKind?,
        size: freezed == size
            ? _value.size
            : size // ignore: cast_nullable_to_non_nullable
                  as int?,
        modifiedAt: freezed == modifiedAt
            ? _value.modifiedAt
            : modifiedAt // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
        isReadable: freezed == isReadable
            ? _value.isReadable
            : isReadable // ignore: cast_nullable_to_non_nullable
                  as bool?,
      ),
    );
  }
}

/// @nodoc

class _$RemoteEntryImpl extends _RemoteEntry {
  const _$RemoteEntryImpl({
    required this.name,
    required this.path,
    required this.kind,
    this.linkTarget,
    this.size,
    this.modifiedAt,
    this.isReadable,
  }) : super._();

  /// The entry's own name, with no path in it.
  @override
  final String name;

  /// The absolute path of this entry on the remote host.
  @override
  final String path;
  @override
  final RemoteEntryKind kind;

  /// For a [RemoteEntryKind.symlink], what the link resolves to.
  ///
  /// Null means "not a symlink, or the target could not be resolved" —
  /// a broken link, or one pointing somewhere the session may not stat.
  /// It is NOT a claim that the target is a file.
  @override
  final RemoteEntryKind? linkTarget;

  /// Size in bytes, or null when the server omitted it.
  ///
  /// Nullable rather than zero-defaulted: every field of
  /// `SftpFileAttrs` is optional in the protocol
  /// (`sftp_file_attrs.dart:157-187`), and a real zero-byte file must
  /// stay distinguishable from a server that simply did not say.
  @override
  final int? size;

  /// Last modification time, or null when the server omitted it.
  @override
  final DateTime? modifiedAt;

  /// Whether this entry is readable — with null meaning "the server did
  /// not give us enough to answer".
  ///
  /// Three-valued ON PURPOSE, and this is the field most likely to look
  /// like an oversight. SFTP reports permission BITS but not whether the
  /// authenticated user owns the file: the `uid`/`gid` in
  /// `SftpFileAttrs` are the FILE's, and the protocol never sends the
  /// session's own. So a mode of `0600` is genuinely unanswerable — it
  /// is readable if we are the owner and refused if we are not, and
  /// nothing on the wire says which.
  ///
  /// Only the two ownership-independent cases are ever asserted: every
  /// read bit set (true), or none set (false). A bool would have forced
  /// one of those guesses onto the middle case, and this codebase does
  /// not represent "unknown" as a definite answer — see
  /// [HostReportStatus.truncated], which exists for the same reason.
  @override
  final bool? isReadable;

  @override
  String toString() {
    return 'RemoteEntry(name: $name, path: $path, kind: $kind, linkTarget: $linkTarget, size: $size, modifiedAt: $modifiedAt, isReadable: $isReadable)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$RemoteEntryImpl &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.path, path) || other.path == path) &&
            (identical(other.kind, kind) || other.kind == kind) &&
            (identical(other.linkTarget, linkTarget) ||
                other.linkTarget == linkTarget) &&
            (identical(other.size, size) || other.size == size) &&
            (identical(other.modifiedAt, modifiedAt) ||
                other.modifiedAt == modifiedAt) &&
            (identical(other.isReadable, isReadable) ||
                other.isReadable == isReadable));
  }

  @override
  int get hashCode => Object.hash(
    runtimeType,
    name,
    path,
    kind,
    linkTarget,
    size,
    modifiedAt,
    isReadable,
  );

  /// Create a copy of RemoteEntry
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$RemoteEntryImplCopyWith<_$RemoteEntryImpl> get copyWith =>
      __$$RemoteEntryImplCopyWithImpl<_$RemoteEntryImpl>(this, _$identity);
}

abstract class _RemoteEntry extends RemoteEntry {
  const factory _RemoteEntry({
    required final String name,
    required final String path,
    required final RemoteEntryKind kind,
    final RemoteEntryKind? linkTarget,
    final int? size,
    final DateTime? modifiedAt,
    final bool? isReadable,
  }) = _$RemoteEntryImpl;
  const _RemoteEntry._() : super._();

  /// The entry's own name, with no path in it.
  @override
  String get name;

  /// The absolute path of this entry on the remote host.
  @override
  String get path;
  @override
  RemoteEntryKind get kind;

  /// For a [RemoteEntryKind.symlink], what the link resolves to.
  ///
  /// Null means "not a symlink, or the target could not be resolved" —
  /// a broken link, or one pointing somewhere the session may not stat.
  /// It is NOT a claim that the target is a file.
  @override
  RemoteEntryKind? get linkTarget;

  /// Size in bytes, or null when the server omitted it.
  ///
  /// Nullable rather than zero-defaulted: every field of
  /// `SftpFileAttrs` is optional in the protocol
  /// (`sftp_file_attrs.dart:157-187`), and a real zero-byte file must
  /// stay distinguishable from a server that simply did not say.
  @override
  int? get size;

  /// Last modification time, or null when the server omitted it.
  @override
  DateTime? get modifiedAt;

  /// Whether this entry is readable — with null meaning "the server did
  /// not give us enough to answer".
  ///
  /// Three-valued ON PURPOSE, and this is the field most likely to look
  /// like an oversight. SFTP reports permission BITS but not whether the
  /// authenticated user owns the file: the `uid`/`gid` in
  /// `SftpFileAttrs` are the FILE's, and the protocol never sends the
  /// session's own. So a mode of `0600` is genuinely unanswerable — it
  /// is readable if we are the owner and refused if we are not, and
  /// nothing on the wire says which.
  ///
  /// Only the two ownership-independent cases are ever asserted: every
  /// read bit set (true), or none set (false). A bool would have forced
  /// one of those guesses onto the middle case, and this codebase does
  /// not represent "unknown" as a definite answer — see
  /// [HostReportStatus.truncated], which exists for the same reason.
  @override
  bool? get isReadable;

  /// Create a copy of RemoteEntry
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$RemoteEntryImplCopyWith<_$RemoteEntryImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
