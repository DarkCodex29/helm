part of '../file_browser_sheet.dart';

/// One sentence per reason a download could not be filed where the user
/// asked.
///
/// Public for the same reason [describeDownloadFailure] is: a widget test
/// asserts on the exact string without reaching into a private widget.
///
/// Every one of these says the file IS still on the device, because that
/// is the fact most at risk of being lost here. The bytes arrived; only
/// the copy into the user's folder did not, and a message that mentioned
/// only the failure would read as a failed download.
String describePublishFailure(PublishFailure failure) => switch (failure) {
  PublishFailure.permissionLost =>
    'The file is on this device, but Helm lost access to your download '
        'folder. Choose it again to keep saving there.',
  PublishFailure.destinationMissing =>
    'The file is on this device. Your download folder no longer exists, so '
        'nothing was saved to it.',
  PublishFailure.storage =>
    'The file is on this device, but there was no room to save a copy in '
        'your download folder.',
  PublishFailure.unknown =>
    'The file is on this device. It could not be saved to your download '
        'folder, and the system did not say why.',
};

/// One sentence per reason a download stopped.
///
/// Public so a widget test can assert on the exact string without reaching
/// into a private widget, matching [describeRemoteEntry].
///
/// Written from the [DownloadFailure] alone and never from the underlying
/// message: [DownloadFailed.detail] carries whatever the server said, and
/// a server-supplied string must not become UI copy.
String describeDownloadFailure(DownloadFailure? failure) => switch (failure) {
  DownloadFailure.permissionDenied =>
    'You do not have permission to read this file.',
  DownloadFailure.notFound => 'This file no longer exists on the host.',
  DownloadFailure.disconnected =>
    'The connection dropped before the file finished downloading.',
  DownloadFailure.stalled =>
    'The download stopped receiving data and was abandoned.',
  DownloadFailure.unknownSize =>
    'The host would not say how large this file is, so it was not downloaded.',
  DownloadFailure.sizeMismatch =>
    'The file arrived incomplete and was discarded.',
  DownloadFailure.storage =>
    'There was not enough room on this device to save the file.',
  DownloadFailure.unknown ||
  null => 'The file could not be downloaded, and the host did not say why.',
};

/// One sentence per reason an upload stopped, mirroring
/// [describeDownloadFailure] exactly: written from the [UploadFailure]
/// alone, never from [UploadFailed.detail] — a server-supplied string must
/// not become UI copy.
String describeUploadFailure(UploadFailure? failure) => switch (failure) {
  UploadFailure.permissionDenied =>
    'You do not have permission to write to this directory.',
  UploadFailure.notFound => 'This directory no longer exists on the host.',
  UploadFailure.disconnected =>
    'The connection dropped before the file finished uploading.',
  UploadFailure.stalled =>
    'The upload stopped receiving acknowledgements and was abandoned.',
  UploadFailure.sourceUnreadable => 'The local file could not be read.',
  UploadFailure.sizeMismatch =>
    'The file did not upload completely and was discarded.',
  UploadFailure.unknown ||
  null => 'The file could not be uploaded, and the host did not say why.',
};

/// One sentence per locally-rejected name, matching [describeDownloadFailure]
/// in being written from the enum alone — there is no server round trip to
/// carry a message, which is the whole point of validating locally.
String describeNameRejection(NameRejection reason) => switch (reason) {
  NameRejection.empty => 'Enter a name.',
  NameRejection.containsSeparator => 'A name cannot contain "/".',
  NameRejection.currentDirectory => '"." is not a usable name.',
  NameRejection.parentDirectory => '".." is not a usable name.',
};

/// One sentence per reason a create, rename or delete was refused by the
/// server, mirroring [describeDownloadFailure]: never built from the
/// underlying message, only from the classified reason.
String describeRemoteWriteFailure(RemoteWriteFailure reason) =>
    switch (reason) {
      RemoteWriteFailure.permissionDenied =>
        'You do not have permission to do this.',
      RemoteWriteFailure.notFound => 'This entry no longer exists on the host.',
      RemoteWriteFailure.disconnected =>
        'The connection dropped before this could finish.',
      RemoteWriteFailure.unknown =>
        'The host refused this, without saying why.',
    };
