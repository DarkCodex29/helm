part of '../file_browser_sheet.dart';

/// A name-entry dialog, as its own [StatefulWidget] rather than a
/// [TextEditingController] built inline by the sheet's method.
///
/// That inline shape was tried first and crashed under test: a controller
/// created and `dispose()`d by a plain method raced the dialog route's own
/// teardown animation, and `TextField` rebuilt against an already-disposed
/// controller while the route was still closing — `ChangeNotifier` used
/// after `dispose()`. Giving the dialog its own `State` makes the
/// controller's lifecycle match the WIDGET that reads it, which is the
/// ownership `TextEditingController`'s own contract assumes and the inline
/// version violated.
class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.confirmSemanticsId,
    this.initialValue,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String confirmSemanticsId;
  final String? initialValue;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        Semantics(
          identifier: widget.confirmSemanticsId,
          child: TextButton(
            onPressed: _submit,
            child: Text(widget.confirmLabel),
          ),
        ),
      ],
    );
  }
}
