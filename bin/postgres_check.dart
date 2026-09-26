import 'dart:io';

import 'package:postgres/postgres.dart';

Future<void> main() async {
  final password = Platform.environment['CITY6_DB_PASSWORD'];

  if (password == null || password.isEmpty) {
    stderr.writeln('CITY6_DB_PASSWORD is not set.');
    exitCode = 1;
    return;
  }

  final connection = await Connection.open(
    Endpoint(
      host: 'localhost',
      port: 5432,
      database: 'city6',
      username: 'city6_app',
      password: password,
    ),
    settings: const ConnectionSettings(
      sslMode: SslMode.disable,
    ),
  );

  try {
    final result = await connection.execute(
      'SELECT current_database(), current_user, 1',
    );

    print('PostgreSQL connection OK');
    print('database: ${result[0][0]}');
    print('user: ${result[0][1]}');
    print('test value: ${result[0][2]}');
  } finally {
    await connection.close();
  }
}