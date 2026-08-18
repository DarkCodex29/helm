// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'project_shortcut.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ProjectShortcutImpl _$$ProjectShortcutImplFromJson(
  Map<String, dynamic> json,
) => _$ProjectShortcutImpl(
  id: json['id'] as String,
  name: json['name'] as String,
  projectPath: json['projectPath'] as String,
  tmuxSession: json['tmuxSession'] as String,
  command: json['command'] as String? ?? '',
  profileId: json['profileId'] as String,
  sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
  sessionRef: _readSessionRef(json, 'sessionRef') as String?,
  multiplexer: json['multiplexer'] as String?,
);

Map<String, dynamic> _$$ProjectShortcutImplToJson(
  _$ProjectShortcutImpl instance,
) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'projectPath': instance.projectPath,
  'tmuxSession': instance.tmuxSession,
  'command': instance.command,
  'profileId': instance.profileId,
  'sortOrder': instance.sortOrder,
  'sessionRef': instance.sessionRef,
  'multiplexer': instance.multiplexer,
};
