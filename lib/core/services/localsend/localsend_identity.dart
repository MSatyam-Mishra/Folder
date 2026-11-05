// Device identity for HTTPS mode: a self-signed X.509 certificate (RSA 2048,
// SHA256withRSA). The LocalSend fingerprint is the SHA-256 of the
// certificate's DER encoding (upper-case hex), so the key and certificate are
// persisted to keep it stable.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:folder/core/services/localsend/localsend_der.dart';
import 'package:folder/core/services/localsend/localsend_hash.dart';
import 'package:folder/core/services/localsend/localsend_models.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

class LsIdentity {
  const LsIdentity({required this.certificatePem, required this.privateKeyPem});

  final String certificatePem;

  /// PKCS#8 PEM.
  final String privateKeyPem;

  static const _certFile = 'localsend_certificate.pem';
  static const _keyFile = 'localsend_private_key.pem';

  Uint8List get certificateDer => Der.pemToDer(certificatePem)!;

  /// Upper-case hex SHA-256 of the certificate (the HTTPS fingerprint).
  String get fingerprint => lsFingerprintOfDer(certificateDer);

  /// Context for the HTTPS server.
  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  /// Context for outgoing requests: presents the device certificate as the
  /// TLS client certificate. Current official LocalSend servers require one
  /// (mutual TLS) and match it against the fingerprint in register requests.
  SecurityContext clientContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  /// Loads the identity from [directory], generating (in a background
  /// isolate) and saving a new one when missing or unreadable.
  static Future<LsIdentity> loadOrCreate(Directory directory) async {
    final certFile = File(
      '${directory.path}${Platform.pathSeparator}$_certFile',
    );
    final keyFile = File('${directory.path}${Platform.pathSeparator}$_keyFile');
    try {
      if (await certFile.exists() && await keyFile.exists()) {
        final identity = LsIdentity(
          certificatePem: await certFile.readAsString(),
          privateKeyPem: await keyFile.readAsString(),
        );
        if (Der.pemToDer(identity.certificatePem) != null &&
            Der.pemToDer(identity.privateKeyPem) != null) {
          identity.serverContext(); // throws when the files are unusable
          return identity;
        }
      }
    } catch (e) {
      LsLog.d('Stored identity unusable, generating a new one: $e');
    }
    final identity = await Isolate.run(generate);
    await directory.create(recursive: true);
    await keyFile.writeAsString(identity.privateKeyPem, flush: true);
    await certFile.writeAsString(identity.certificatePem, flush: true);
    return identity;
  }

  /// Generates a new key pair and self-signed certificate. CPU heavy (RSA key
  /// generation): call it off the UI isolate.
  static LsIdentity generate() {
    final random = FortunaRandom();
    final seedSource = Random.secure();
    random.seed(
      KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256))),
      ),
    );
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    final publicKey = pair.publicKey;
    final privateKey = pair.privateKey;

    final n = publicKey.modulus!;
    final e = publicKey.publicExponent!;
    final d = privateKey.privateExponent!;
    final p = privateKey.p!;
    final q = privateKey.q!;

    const rsaEncryption = '1.2.840.113549.1.1.1';
    const sha256WithRsa = '1.2.840.113549.1.1.11';
    const commonName = '2.5.4.3';

    final rsaPrivateKey = Der.sequence([
      Der.smallInt(0),
      Der.integer(n),
      Der.integer(e),
      Der.integer(d),
      Der.integer(p),
      Der.integer(q),
      Der.integer(d % (p - BigInt.one)),
      Der.integer(d % (q - BigInt.one)),
      Der.integer(q.modInverse(p)),
    ]);
    final pkcs8 = Der.sequence([
      Der.smallInt(0),
      Der.sequence([Der.oid(rsaEncryption), Der.nullValue()]),
      Der.octetString(rsaPrivateKey),
    ]);

    final name = Der.sequence([
      Der.set([
        Der.sequence([Der.oid(commonName), Der.utf8String('LocalSend User')]),
      ]),
    ]);
    final serialBytes = List<int>.generate(16, (_) => seedSource.nextInt(256));
    serialBytes[0] = (serialBytes[0] & 0x7f) | 0x01;
    final serial = BigInt.parse(
      serialBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
    final now = DateTime.now().toUtc();
    final notBefore = now.subtract(const Duration(days: 1));
    final notAfter = DateTime.utc(now.year + 100, now.month, 1);
    final signatureAlgorithm = Der.sequence([
      Der.oid(sha256WithRsa),
      Der.nullValue(),
    ]);

    final tbs = Der.sequence([
      Der.explicit(0, Der.smallInt(2)), // X.509 v3
      Der.integer(serial),
      signatureAlgorithm,
      name,
      Der.sequence([Der.time(notBefore), Der.time(notAfter)]),
      name,
      Der.sequence([
        Der.sequence([Der.oid(rsaEncryption), Der.nullValue()]),
        Der.bitString(Der.sequence([Der.integer(n), Der.integer(e)])),
      ]),
    ]);

    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final signature = signer.generateSignature(tbs);
    final certificate = Der.sequence([
      tbs,
      signatureAlgorithm,
      Der.bitString(signature.bytes),
    ]);

    return LsIdentity(
      certificatePem: Der.pem('CERTIFICATE', certificate),
      privateKeyPem: Der.pem('PRIVATE KEY', pkcs8),
    );
  }
}

/// Upper-case hex SHA-256 of a DER certificate.
String lsFingerprintOfDer(List<int> der) =>
    lsHex(LsSha256.of(der), upper: true);
