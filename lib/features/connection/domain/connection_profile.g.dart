// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_profile.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ConnectionProfileImpl _$$ConnectionProfileImplFromJson(
  Map<String, dynamic> json,
) => _$ConnectionProfileImpl(
  id: json['id'] as String,
  name: json['name'] as String,
  host: json['host'] as String,
  port: (json['port'] as num?)?.toInt() ?? 22,
  username: json['username'] as String,
  tmuxSession: json['tmuxSession'] as String?,
  sessionRef: _readSessionRef(json, 'sessionRef') as String?,
  multiplexer: json['multiplexer'] as String?,
  isDefault: json['isDefault'] as bool? ?? false,
  holdInBackground: json['holdInBackground'] as bool? ?? false,
);

Map<String, dynamic> _$$ConnectionProfileImplToJson(
  _$ConnectionProfileImpl instance,
) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'host': instance.host,
  'port': instance.port,
  'username': instance.username,
  'tmuxSession': instance.tmuxSession,
  'sessionRef': instance.sessionRef,
  'multiplexer': instance.multiplexer,
  'isDefault': instance.isDefault,
  'holdInBackground': instance.holdInBackground,
};
