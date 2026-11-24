// Copyright (c) Joel Benway
// SPDX-License-Identifier: MIT
//
// Minimal Qt6Keychain CLI helper: reads a UTF-8 secret from stdin (EOF-delimited,
// exact bytes preserved) and writes it to QtKeychain under (service, key) if not
// already identical. Prints "updated" or "unchanged" to stdout on success.
// Exit codes: 0 = ok, 1 = permanent error, 2 = usage error, 3 = retryable backend/locked error.
// Never logs secrets.

#include <QCoreApplication>
#include <QEventLoop>
#include <QString>
#include <QStringDecoder>
#include <qt6keychain/keychain.h>

#include <cstddef>
#include <cstdio>
#include <iostream>

static int exitCodeForKeychainError(QKeychain::Error err) {
  switch (err) {
    case QKeychain::NoBackendAvailable:
    case QKeychain::AccessDeniedByUser:
    case QKeychain::AccessDenied:
      return 3;
    default:
      return 1;
  }
}

int main(int argc, char *argv[]) {
  QCoreApplication app(argc, argv);

  const QStringList args = app.arguments();
  if (args.size() != 3 || args.at(1).isEmpty() || args.at(2).isEmpty()) {
    std::cerr << "Usage: kmail-keychain-set <service> <key> < secret\n";
    return 2;
  }

  const QString service = args.at(1);
  const QString key = args.at(2);

  QByteArray raw;
  char buf[4096];
  while (true) {
    const std::size_t n = std::fread(buf, 1, sizeof(buf), stdin);
    if (n > 0) {
      raw.append(buf, static_cast<qsizetype>(n));
    }
    if (n < sizeof(buf)) {
      if (std::ferror(stdin) != 0) {
        std::cerr << "kmail-keychain-set: failed reading stdin\n";
        return 1;
      }
      break;
    }
  }
  QStringDecoder utf8Decoder(
      QStringDecoder::Utf8, QStringConverter::Flag::ConvertInitialBom);
  const QString password = utf8Decoder(raw);
  // QtKeychain's ReadPasswordJob::textData() decodes UTF-8 via QString::fromUtf8(),
  // which strips a leading U+FEFF BOM. Reject before touching any existing wallet entry.
  if (password.startsWith(QChar(0xFEFF))) {
    std::cerr << "kmail-keychain-set: passwords starting with U+FEFF (BOM) are unsupported by QtKeychain/KMail\n";
    return 1;
  }

  // Check if the keychain already holds the exact same password.
  QKeychain::ReadPasswordJob readJob(service);
  readJob.setAutoDelete(false);
  readJob.setKey(key);
  {
    QEventLoop loop;
    QObject::connect(&readJob, &QKeychain::Job::finished, &loop, &QEventLoop::quit);
    readJob.start();
    loop.exec();
  }

  if (readJob.error() == QKeychain::NoError && readJob.textData() == password) {
    std::cout << "unchanged\n";
    return 0;
  }
  if (readJob.error() != QKeychain::NoError && readJob.error() != QKeychain::EntryNotFound) {
    std::cerr << "kmail-keychain-set: read failed: "
              << readJob.errorString().toStdString() << "\n";
    return exitCodeForKeychainError(readJob.error());
  }

  QKeychain::WritePasswordJob writeJob(service);
  writeJob.setAutoDelete(false);
  writeJob.setKey(key);
  writeJob.setTextData(password);
  {
    QEventLoop loop;
    QObject::connect(&writeJob, &QKeychain::Job::finished, &loop, &QEventLoop::quit);
    writeJob.start();
    loop.exec();
  }

  if (writeJob.error() != QKeychain::NoError) {
    std::cerr << "kmail-keychain-set: write failed: "
              << writeJob.errorString().toStdString() << "\n";
    return exitCodeForKeychainError(writeJob.error());
  }

  // Confirm the backend persisted the exact credential before reporting "updated"
  // (QtKeychain's KWallet handler can complete with NoError if the wallet closed mid-write).
  QKeychain::ReadPasswordJob verifyJob(service);
  verifyJob.setAutoDelete(false);
  verifyJob.setKey(key);
  {
    QEventLoop loop;
    QObject::connect(&verifyJob, &QKeychain::Job::finished, &loop, &QEventLoop::quit);
    verifyJob.start();
    loop.exec();
  }

  if (verifyJob.error() != QKeychain::NoError) {
    std::cerr << "kmail-keychain-set: write verification failed: "
              << verifyJob.errorString().toStdString() << "\n";
    if (verifyJob.error() == QKeychain::EntryNotFound) {
      return 3;
    }
    return exitCodeForKeychainError(verifyJob.error());
  }
  if (verifyJob.textData() != password) {
    std::cerr << "kmail-keychain-set: write verification failed: stored credential does not match expected value\n";
    return 3;
  }

  std::cout << "updated\n";
  return 0;
}
