// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'host_report.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$HostReport {
  HostReportStatus get status => throw _privateConstructorUsedError;
  Map<String, String> get env => throw _privateConstructorUsedError;
  List<
    ({
      String absPath,
      bool found,
      String id,
      bool onInheritedPath,
      String version,
    })
  >
  get mux => throw _privateConstructorUsedError;
  List<({String attached, String muxId, String name, String state})>
  get sessions => throw _privateConstructorUsedError;
  List<
    ({String label, String muxId, String session, String state, String target})
  >
  get agents => throw _privateConstructorUsedError;
  List<({String detail, String id, String status})> get diagnostics =>
      throw _privateConstructorUsedError;
  List<({String detail, String scope})> get errors =>
      throw _privateConstructorUsedError;
  int? get elapsedMs => throw _privateConstructorUsedError;

  /// Create a copy of HostReport
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $HostReportCopyWith<HostReport> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $HostReportCopyWith<$Res> {
  factory $HostReportCopyWith(
    HostReport value,
    $Res Function(HostReport) then,
  ) = _$HostReportCopyWithImpl<$Res, HostReport>;
  @useResult
  $Res call({
    HostReportStatus status,
    Map<String, String> env,
    List<
      ({
        String absPath,
        bool found,
        String id,
        bool onInheritedPath,
        String version,
      })
    >
    mux,
    List<({String attached, String muxId, String name, String state})> sessions,
    List<
      ({
        String label,
        String muxId,
        String session,
        String state,
        String target,
      })
    >
    agents,
    List<({String detail, String id, String status})> diagnostics,
    List<({String detail, String scope})> errors,
    int? elapsedMs,
  });
}

/// @nodoc
class _$HostReportCopyWithImpl<$Res, $Val extends HostReport>
    implements $HostReportCopyWith<$Res> {
  _$HostReportCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of HostReport
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? env = null,
    Object? mux = null,
    Object? sessions = null,
    Object? agents = null,
    Object? diagnostics = null,
    Object? errors = null,
    Object? elapsedMs = freezed,
  }) {
    return _then(
      _value.copyWith(
            status: null == status
                ? _value.status
                : status // ignore: cast_nullable_to_non_nullable
                      as HostReportStatus,
            env: null == env
                ? _value.env
                : env // ignore: cast_nullable_to_non_nullable
                      as Map<String, String>,
            mux: null == mux
                ? _value.mux
                : mux // ignore: cast_nullable_to_non_nullable
                      as List<
                        ({
                          String absPath,
                          bool found,
                          String id,
                          bool onInheritedPath,
                          String version,
                        })
                      >,
            sessions: null == sessions
                ? _value.sessions
                : sessions // ignore: cast_nullable_to_non_nullable
                      as List<
                        ({
                          String attached,
                          String muxId,
                          String name,
                          String state,
                        })
                      >,
            agents: null == agents
                ? _value.agents
                : agents // ignore: cast_nullable_to_non_nullable
                      as List<
                        ({
                          String label,
                          String muxId,
                          String session,
                          String state,
                          String target,
                        })
                      >,
            diagnostics: null == diagnostics
                ? _value.diagnostics
                : diagnostics // ignore: cast_nullable_to_non_nullable
                      as List<({String detail, String id, String status})>,
            errors: null == errors
                ? _value.errors
                : errors // ignore: cast_nullable_to_non_nullable
                      as List<({String detail, String scope})>,
            elapsedMs: freezed == elapsedMs
                ? _value.elapsedMs
                : elapsedMs // ignore: cast_nullable_to_non_nullable
                      as int?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$HostReportImplCopyWith<$Res>
    implements $HostReportCopyWith<$Res> {
  factory _$$HostReportImplCopyWith(
    _$HostReportImpl value,
    $Res Function(_$HostReportImpl) then,
  ) = __$$HostReportImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    HostReportStatus status,
    Map<String, String> env,
    List<
      ({
        String absPath,
        bool found,
        String id,
        bool onInheritedPath,
        String version,
      })
    >
    mux,
    List<({String attached, String muxId, String name, String state})> sessions,
    List<
      ({
        String label,
        String muxId,
        String session,
        String state,
        String target,
      })
    >
    agents,
    List<({String detail, String id, String status})> diagnostics,
    List<({String detail, String scope})> errors,
    int? elapsedMs,
  });
}

/// @nodoc
class __$$HostReportImplCopyWithImpl<$Res>
    extends _$HostReportCopyWithImpl<$Res, _$HostReportImpl>
    implements _$$HostReportImplCopyWith<$Res> {
  __$$HostReportImplCopyWithImpl(
    _$HostReportImpl _value,
    $Res Function(_$HostReportImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of HostReport
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? env = null,
    Object? mux = null,
    Object? sessions = null,
    Object? agents = null,
    Object? diagnostics = null,
    Object? errors = null,
    Object? elapsedMs = freezed,
  }) {
    return _then(
      _$HostReportImpl(
        status: null == status
            ? _value.status
            : status // ignore: cast_nullable_to_non_nullable
                  as HostReportStatus,
        env: null == env
            ? _value._env
            : env // ignore: cast_nullable_to_non_nullable
                  as Map<String, String>,
        mux: null == mux
            ? _value._mux
            : mux // ignore: cast_nullable_to_non_nullable
                  as List<
                    ({
                      String absPath,
                      bool found,
                      String id,
                      bool onInheritedPath,
                      String version,
                    })
                  >,
        sessions: null == sessions
            ? _value._sessions
            : sessions // ignore: cast_nullable_to_non_nullable
                  as List<
                    ({String attached, String muxId, String name, String state})
                  >,
        agents: null == agents
            ? _value._agents
            : agents // ignore: cast_nullable_to_non_nullable
                  as List<
                    ({
                      String label,
                      String muxId,
                      String session,
                      String state,
                      String target,
                    })
                  >,
        diagnostics: null == diagnostics
            ? _value._diagnostics
            : diagnostics // ignore: cast_nullable_to_non_nullable
                  as List<({String detail, String id, String status})>,
        errors: null == errors
            ? _value._errors
            : errors // ignore: cast_nullable_to_non_nullable
                  as List<({String detail, String scope})>,
        elapsedMs: freezed == elapsedMs
            ? _value.elapsedMs
            : elapsedMs // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// @nodoc

class _$HostReportImpl implements _HostReport {
  const _$HostReportImpl({
    required this.status,
    final Map<String, String> env = const {},
    final List<
          ({
            String absPath,
            bool found,
            String id,
            bool onInheritedPath,
            String version,
          })
        >
        mux =
        const [],
    final List<({String attached, String muxId, String name, String state})>
        sessions =
        const [],
    final List<
          ({
            String label,
            String muxId,
            String session,
            String state,
            String target,
          })
        >
        agents =
        const [],
    final List<({String detail, String id, String status})> diagnostics =
        const [],
    final List<({String detail, String scope})> errors = const [],
    this.elapsedMs,
  }) : _env = env,
       _mux = mux,
       _sessions = sessions,
       _agents = agents,
       _diagnostics = diagnostics,
       _errors = errors;

  @override
  final HostReportStatus status;
  final Map<String, String> _env;
  @override
  @JsonKey()
  Map<String, String> get env {
    if (_env is EqualUnmodifiableMapView) return _env;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_env);
  }

  final List<
    ({
      String absPath,
      bool found,
      String id,
      bool onInheritedPath,
      String version,
    })
  >
  _mux;
  @override
  @JsonKey()
  List<
    ({
      String absPath,
      bool found,
      String id,
      bool onInheritedPath,
      String version,
    })
  >
  get mux {
    if (_mux is EqualUnmodifiableListView) return _mux;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_mux);
  }

  final List<({String attached, String muxId, String name, String state})>
  _sessions;
  @override
  @JsonKey()
  List<({String attached, String muxId, String name, String state})>
  get sessions {
    if (_sessions is EqualUnmodifiableListView) return _sessions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_sessions);
  }

  final List<
    ({String label, String muxId, String session, String state, String target})
  >
  _agents;
  @override
  @JsonKey()
  List<
    ({String label, String muxId, String session, String state, String target})
  >
  get agents {
    if (_agents is EqualUnmodifiableListView) return _agents;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_agents);
  }

  final List<({String detail, String id, String status})> _diagnostics;
  @override
  @JsonKey()
  List<({String detail, String id, String status})> get diagnostics {
    if (_diagnostics is EqualUnmodifiableListView) return _diagnostics;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_diagnostics);
  }

  final List<({String detail, String scope})> _errors;
  @override
  @JsonKey()
  List<({String detail, String scope})> get errors {
    if (_errors is EqualUnmodifiableListView) return _errors;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_errors);
  }

  @override
  final int? elapsedMs;

  @override
  String toString() {
    return 'HostReport(status: $status, env: $env, mux: $mux, sessions: $sessions, agents: $agents, diagnostics: $diagnostics, errors: $errors, elapsedMs: $elapsedMs)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$HostReportImpl &&
            (identical(other.status, status) || other.status == status) &&
            const DeepCollectionEquality().equals(other._env, _env) &&
            const DeepCollectionEquality().equals(other._mux, _mux) &&
            const DeepCollectionEquality().equals(other._sessions, _sessions) &&
            const DeepCollectionEquality().equals(other._agents, _agents) &&
            const DeepCollectionEquality().equals(
              other._diagnostics,
              _diagnostics,
            ) &&
            const DeepCollectionEquality().equals(other._errors, _errors) &&
            (identical(other.elapsedMs, elapsedMs) ||
                other.elapsedMs == elapsedMs));
  }

  @override
  int get hashCode => Object.hash(
    runtimeType,
    status,
    const DeepCollectionEquality().hash(_env),
    const DeepCollectionEquality().hash(_mux),
    const DeepCollectionEquality().hash(_sessions),
    const DeepCollectionEquality().hash(_agents),
    const DeepCollectionEquality().hash(_diagnostics),
    const DeepCollectionEquality().hash(_errors),
    elapsedMs,
  );

  /// Create a copy of HostReport
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$HostReportImplCopyWith<_$HostReportImpl> get copyWith =>
      __$$HostReportImplCopyWithImpl<_$HostReportImpl>(this, _$identity);
}

abstract class _HostReport implements HostReport {
  const factory _HostReport({
    required final HostReportStatus status,
    final Map<String, String> env,
    final List<
      ({
        String absPath,
        bool found,
        String id,
        bool onInheritedPath,
        String version,
      })
    >
    mux,
    final List<({String attached, String muxId, String name, String state})>
    sessions,
    final List<
      ({
        String label,
        String muxId,
        String session,
        String state,
        String target,
      })
    >
    agents,
    final List<({String detail, String id, String status})> diagnostics,
    final List<({String detail, String scope})> errors,
    final int? elapsedMs,
  }) = _$HostReportImpl;

  @override
  HostReportStatus get status;
  @override
  Map<String, String> get env;
  @override
  List<
    ({
      String absPath,
      bool found,
      String id,
      bool onInheritedPath,
      String version,
    })
  >
  get mux;
  @override
  List<({String attached, String muxId, String name, String state})>
  get sessions;
  @override
  List<
    ({String label, String muxId, String session, String state, String target})
  >
  get agents;
  @override
  List<({String detail, String id, String status})> get diagnostics;
  @override
  List<({String detail, String scope})> get errors;
  @override
  int? get elapsedMs;

  /// Create a copy of HostReport
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$HostReportImplCopyWith<_$HostReportImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
