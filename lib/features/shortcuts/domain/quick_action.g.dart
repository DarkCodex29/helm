// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quick_action.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$QuickActionImpl _$$QuickActionImplFromJson(Map<String, dynamic> json) =>
    _$QuickActionImpl(
      id: json['id'] as String,
      label: json['label'] as String,
      command: json['command'] as String,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$QuickActionImplToJson(_$QuickActionImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'label': instance.label,
      'command': instance.command,
      'sortOrder': instance.sortOrder,
    };
