import 'dart:math';
import 'package:bcrypt/bcrypt.dart';

void main() {
  final random = Random.secure();
  final password = List.generate(
    24,
    (_) => random.nextInt(10),
  ).join();

  final hash = BCrypt.hashpw(password, BCrypt.gensalt());

  print('TEST_PASSWORD=$password');
  print('PASSWORD_HASH=$hash');
}