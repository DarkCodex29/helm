/// Wraps [value] in POSIX single quotes so it reaches a remote login shell
/// as exactly one literal argument, regardless of embedded shell
/// metacharacters (`;`, `$()`, backticks, a leading `-`, etc.).
///
/// A single-quoted string cannot itself contain an unescaped single quote,
/// so each embedded `'` is closed, escaped as a literal quote outside the
/// quoted section, then reopened — the standard `'\''` idiom.
///
/// See design.md AD-3: session names are user-controlled and reach a
/// remote shell, so this is a correctness boundary, not polish.
String shellQuote(String value) {
  return "'${value.replaceAll("'", r"'\''")}'";
}
