import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folder/core/formats/blend/blend_file.dart';
import 'package:folder/core/formats/blend/blend_to_gltf.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures made with Blender 4.2 (see scene.json for what Blender itself
/// reported about them).
Uint8List fixture(String name) =>
    File('test/fixtures/blend/$name').readAsBytesSync();

Map<String, Object?> glbJson(Uint8List glb) {
  final view = ByteData.sublistView(glb);
  expect(view.getUint32(0, Endian.little), 0x46546C67);
  expect(view.getUint32(8, Endian.little), glb.length);
  final length = view.getUint32(12, Endian.little);
  return jsonDecode(utf8.decode(glb.sublist(20, 20 + length)))
      as Map<String, Object?>;
}

void main() {
  final expected =
      (jsonDecode(File('test/fixtures/blend/scene.json').readAsStringSync())
              as Map<String, Object?>)['objects']!
          as Map<String, Object?>;

  void checkScene(BlendExport result) {
    expect(result.version, '4.2');
    expect(result.otherObjects, 2, reason: 'camera and light');
    expect(result.truncated, isFalse);
    expect({for (final m in result.meshes) m.name}, expected.keys.toSet());
    for (final mesh in result.meshes) {
      final facts = expected[mesh.name]! as Map<String, Object?>;
      expect(mesh.triangles, facts['tris'], reason: mesh.name);
      final min = (facts['bbox_min']! as List).cast<num>();
      final max = (facts['bbox_max']! as List).cast<num>();
      for (var i = 0; i < 3; i++) {
        expect(
          mesh.min[i],
          closeTo(min[i], 1e-4),
          reason: '${mesh.name} min $i',
        );
        expect(
          mesh.max[i],
          closeTo(max[i], 1e-4),
          reason: '${mesh.name} max $i',
        );
      }
    }

    final gltf = glbJson(result.glb!);
    final materials = {
      for (final m in (gltf['materials']! as List).cast<Map<String, Object?>>())
        m['name']: m['pbrMetallicRoughness']! as Map<String, Object?>,
    };
    expect(materials['Red']!['baseColorFactor'], [1.0, 0.0, 0.0, 1.0]);
    expect((materials['Blue']!['baseColorFactor']! as List)[2], 1.0);
    expect(materials['Blue']!['metallicFactor'], 1.0);
    expect(materials['Green']!['baseColorFactor'], [0.0, 1.0, 0.0, 1.0]);

    // The sphere uses both of its materials; positions are Y-up.
    final meshes = (gltf['meshes']! as List).cast<Map<String, Object?>>();
    final sphere = meshes.firstWhere((m) => m['name'] == 'BlueSphere');
    expect((sphere['primitives']! as List).length, 2);
    final accessors = (gltf['accessors']! as List).cast<Map<String, Object?>>();
    final cube = meshes.firstWhere((m) => m['name'] == 'RedCube');
    final cubePrim =
        (cube['primitives']! as List).first as Map<String, Object?>;
    final cubePos =
        accessors[(cubePrim['attributes']! as Map)['POSITION'] as int];
    // Flat cube: 4 corners per face, 6 faces.
    expect(cubePos['count'], 24);
    final plane = meshes.firstWhere((m) => m['name'] == 'MirroredPlane');
    final planePrim =
        (plane['primitives']! as List).first as Map<String, Object?>;
    final planePos =
        accessors[(planePrim['attributes']! as Map)['POSITION'] as int];
    // Blender z = -3 becomes glTF y = -3.
    expect((planePos['min']! as List)[1], closeTo(-3, 1e-5));
  }

  test('reads a gzip-compressed .blend (Blender 2.x style)', () {
    checkScene(BlendToGltf.convert(fixture('scene_gzip.blend')));
  });

  test('reads the same scene saved with Blender\'s zstd compression', () {
    checkScene(BlendToGltf.convert(fixture('scene_compressed.blend')));
  });

  test('a file without meshes has nothing to show', () {
    final result = BlendToGltf.convert(fixture('no_mesh_gzip.blend'));
    expect(result.glb, isNull);
    expect(result.meshes, isEmpty);
    expect(result.otherObjects, 1);
  });

  test('stops at the triangle budget', () {
    final result = BlendToGltf.convert(
      fixture('scene_gzip.blend'),
      maxTriangles: 20,
    );
    expect(result.truncated, isTrue);
    expect(
      result.meshes.map((m) => m.name),
      containsAll(['RedCube', 'MirroredPlane']),
    );
  });

  test('rejects other files', () {
    expect(
      () => BlendFile.parse(Uint8List.fromList(utf8.encode('hello'))),
      throwsFormatException,
    );
    expect(BlendFile.looksLikeBlend(fixture('scene_gzip.blend')), isTrue);
  });
}
