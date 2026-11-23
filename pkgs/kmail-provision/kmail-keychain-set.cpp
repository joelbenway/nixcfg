// Copyright (c) Joel Benway
// SPDX-License-Identifier: MIT
//
// Minimal Qt6Keychain CLI helper: reads a UTF-8 secret from stdin and writes it
// to QtKeychain under (service, key) if not already identical. Prints "updated"
// or "unchanged" to stdout on success. Never logs secrets.

#include <QCoreApplication>
#include <QEventLoop>
#include <QFile>
#include <QString>
#include <qt6keychain/keychain.h>

#include <cstdio>
#include <iostream>

int main(int argc, char *argv[]) {
  QCoreApplication app(argc, argv);

  const QStringList args = app.arguments();
  if (args.size() != 3 || args.at(1).isEmpty() || args.at(2).isEmpty()) {
    std::cerr << "Usage: kmail-keychain-set <service> <key> < secret\n";
    return 2;
  }

  const QString service = args.at(1);
  const QString key = args.at(2);

  QFile stdinFile;
  if (!stdinFile.open(stdin, QIODevice::ReadOnly)) {
    std::cerr << "kmail-keychain-set: failed to open stdin\n";
    return 1;
  }
  QByteArray raw = stdinFile.readAll();
  if (raw.endsWith("\r\n")) {
    raw.chop(2);
  } else if (raw.endsWith('\n')) {
    raw.chop(1);
  }
  const QString password = QString::fromUtf8(raw);

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
    std::cerr << "kmail-keychain-set: keychain read failed: "
              << readJob.errorString().toStdString() << "\n";
    return 1;
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
    std::cerr << "kmail-keychain-set: keychain write failed: "
              << writeJob.errorString().toStdString() << "\n";
    return 1;
  }

  std::cout << "updated\n";
  return 0;
}
