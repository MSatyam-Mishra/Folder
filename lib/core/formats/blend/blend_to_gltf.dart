import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/blend/blend_file.dart';

/// What [BlendToGltf.convert] found in a .blend file.
class BlendExport {
  const BlendExport({
    required this.glb,
    required this.version,
    required this.meshes,
    required this.otherObjects,
    required this.truncated,
    required this.thumbnail,
  });

  /// The meshes as a binary glTF, or null when there are none.
  final Uint8List? glb;

  /// "4.2"
  final String version;
  final List<BlendMeshInfo> meshes;

  /// Objects without geometry the viewer can show (cameras, lights,
  /// curves, empties…).
  final int otherObjects;

  /// The file has more triangles than the viewer takes; some meshes were
  /// left out.
  final bool truncated;
  final ({int width, int height, Uint8List rgba})? thumbnail;
}

class BlendMeshInfo {
  const BlendMeshInfo(this.name, this.triangles, this.min, this.max);

  final String name;
  final int triangles;

  /// World-space bounds in Blender's own axes (Z up).
  final List<double> min;
  final List<double> max;
}

/// Converts the mesh objects of a .blend file to glTF (GLB) for the 3D
/// viewer: geometry in world space, smooth/flat shading and material
/// colours. Modifiers, textures, curves and instanced collections aren't
/// evaluated (Blender isn't running).
abstract final class BlendToGltf {
  static BlendExport convert(Uint8List bytes, {int maxTriangles = 3000000}) {
    final file = BlendFile.parse(bytes);
    final builder = _GltfBuilder();
    final meshes = <BlendMeshInfo>[];
    var others = 0;
    var budget = maxTriangles;
    var truncated = false;

    for (final block in file.blocks) {
      if (block.code != 'OB') continue;
      final ob = file.structOf(block);
      if (ob == null || ob.type.name != 'Object') continue;
      final mesh = ob.integer('type') == 1 ? ob.follow('data') : null;
      if (mesh == null || mesh.type.name != 'Mesh') {
        others++;
        continue;
      }
      final geometry = _MeshReader(file, mesh).read();
      if (geometry == null || geometry.triangles == 0) {
        others++;
        continue;
      }
      if (geometry.triangles > budget) {
        truncated = true;
        continue;
      }
      budget -= geometry.triangles;
      final name = _idName(ob);
      final info = builder.addObject(name, geometry, _Matrix.world(ob), [
        for (final m in _MeshReader.materials(file, mesh)) _material(m),
      ]);
      meshes.add(info);
    }

    return BlendExport(
      glb: meshes.isEmpty ? null : builder.encode(),
      version: file.versionLabel,
      meshes: meshes,
      otherObjects: others,
      truncated: truncated,
      thumbnail: file.thumbnail(),
    );
  }

  static String _idName(BlendStruct s) {
    final name = s.embedded('id')?.string('name') ?? '';
    return name.length > 2 ? name.substring(2) : name;
  }

  /// Base colour, metallic and roughness: from the Principled BSDF node
  /// when the material uses nodes, else its viewport display settings.
  static _Material _material(BlendStruct? mat) {
    if (mat == null) return _Material.fallback;
    var color = [
      mat.float('r'),
      mat.float('g'),
      mat.float('b'),
      mat.has('a') ? mat.float('a') : 1.0,
    ];
    var metallic = mat.float('metallic');
    var roughness = mat.has('roughness') ? mat.float('roughness') : 0.5;
    final tree = mat.integer('use_nodes') != 0 ? mat.follow('nodetree') : null;
    final principled = tree == null ? null : _principled(tree);
    if (principled != null) {
      final base = principled['Base Color'];
      if (base != null && base.length >= 3) {
        color = [base[0], base[1], base[2], principled['Alpha']?.first ?? 1.0];
      }
      metallic = principled['Metallic']?.first ?? metallic;
      roughness = principled['Roughness']?.first ?? roughness;
    }
    return _Material(
      _idName(mat),
      [for (final c in color) c.clamp(0.0, 1.0)],
      metallic.clamp(0.0, 1.0),
      roughness.clamp(0.0, 1.0),
    );
  }

  /// Unlinked input values of the tree's Principled BSDF, by socket name.
  static Map<String, List<double>>? _principled(BlendStruct tree) {
    final file = tree.file;
    final linked = <int>{};
    for (final link in _list(tree, 'links', 'bNodeLink')) {
      linked.add(link.pointer('tosock'));
    }
    for (final node in _list(tree, 'nodes', 'bNode')) {
      if (node.string('idname') != 'ShaderNodeBsdfPrincipled') continue;
      final values = <String, List<double>>{};
      final inputs = node.embedded('inputs');
      for (final socket in _listFrom(file, inputs, 'bNodeSocket')) {
        final name = socket.string('name');
        final address = socket.offset;
        final block = file.blockAt(socket.pointer('default_value'));
        if (block == null || _isLinked(file, linked, address)) continue;
        final type = name == 'Base Color'
            ? 'bNodeSocketValueRGBA'
            : 'bNodeSocketValueFloat';
        final value = file.structAs(block, type);
        if (value == null) continue;
        values[name] = name == 'Base Color'
            ? (value.floats('value') ?? const [])
            : [value.float('value')];
      }
      return values;
    }
    return null;
  }

  /// Whether the socket at file offset [offset] is the target of a link.
  static bool _isLinked(BlendFile file, Set<int> linked, int offset) {
    for (final address in linked) {
      final block = file.blockAt(address);
      if (block != null && block.offset == offset) return true;
    }
    return false;
  }

  static Iterable<BlendStruct> _list(
    BlendStruct owner,
    String field,
    String type,
  ) => _listFrom(owner.file, owner.embedded(field), type);

  /// Walks a ListBase (first/next pointers).
  static Iterable<BlendStruct> _listFrom(
    BlendFile file,
    BlendStruct? list,
    String type,
  ) sync* {
    if (list == null) return;
    var address = list.pointer('first');
    var guard = 0;
    while (address != 0 && guard++ < 100000) {
      final block = file.blockAt(address);
      if (block == null) return;
      final item = file.structAs(block, type);
      if (item == null) return;
      yield item;
      address = item.pointer('next');
    }
  }
}

class _Material {
  const _Material(this.name, this.color, this.metallic, this.roughness);

  static const fallback = _Material('Default', [0.8, 0.8, 0.8, 1.0], 0, 0.5);

  final String name;
  final List<double> color;
  final double metallic;
  final double roughness;
}

/// A mesh's polygons, in object space.
class _Geometry {
  _Geometry(
    this.positions,
    this.faceStarts,
    this.corners,
    this.materialIndex,
    this.smooth,
  );

  final Float32List positions;

  /// Polygon i uses corners[faceStarts[i]] … corners[faceStarts[i + 1] - 1].
  final Int32List faceStarts;
  final Int32List corners;
  final List<int>? materialIndex;

  /// Per-face smooth shading (null: all smooth).
  final List<bool>? smooth;

  int get faceCount => faceStarts.length - 1;
  int get vertexCount => positions.length ~/ 3;

  int get triangles {
    var n = 0;
    for (var f = 0; f < faceCount; f++) {
      final k = faceStarts[f + 1] - faceStarts[f];
      if (k >= 3) n += k - 2;
    }
    return n;
  }
}

/// Reads a Mesh in whichever layout its Blender version used: generic
/// attributes (3.4+), MPoly/MLoop (2.63–3.x) or MFace (older).
class _MeshReader {
  _MeshReader(this.file, this.mesh);

  final BlendFile file;
  final BlendStruct mesh;

  int _count(List<String> names) {
    final name = mesh.pick(names);
    return name == null ? 0 : mesh.integer(name);
  }

  /// CustomData layers by name: (data block, element count).
  Map<String, BlendBlock> _layers(List<String> fieldNames) {
    final name = mesh.pick(fieldNames);
    final data = name == null ? null : mesh.embedded(name);
    if (data == null) return const {};
    final block = file.blockAt(data.pointer('layers'));
    final total = data.integer('totlayer');
    if (block == null) return const {};
    final result = <String, BlendBlock>{};
    for (var i = 0; i < total; i++) {
      final layer = file.structAs(block, 'CustomDataLayer', i);
      if (layer == null) break;
      final dataBlock = file.blockAt(layer.pointer('data'));
      if (dataBlock != null) {
        result.putIfAbsent(layer.string('name'), () => dataBlock);
      }
    }
    return result;
  }

  _Geometry? read() {
    final verts = _count(['verts_num', 'totvert']);
    if (verts <= 0) return null;
    final vertLayers = _layers(['vert_data', 'vdata']);
    final faceLayers = _layers(['face_data', 'pdata']);
    final cornerLayers = _layers(['corner_data', 'ldata']);

    // Positions.
    Float32List? positions;
    final position = vertLayers['position'];
    if (position != null && position.length >= verts * 12) {
      positions = Float32List.sublistView(file.floats(position), 0, verts * 3);
    } else {
      positions = _legacyPositions(verts);
    }
    if (positions == null) return null;

    var faces = _count(['faces_num', 'totpoly']);
    final cornerCount = _count(['corners_num', 'totloop']);
    Int32List? faceStarts;
    Int32List? corners;
    List<int>? materials;
    List<bool>? smooth;

    final offsetsBlock = file.blockAt(
      mesh.pointer(
        mesh.pick(['face_offset_indices', 'poly_offset_indices']) ?? '',
      ),
    );
    if (offsetsBlock != null && faces > 0) {
      faceStarts = Int32List.sublistView(file.ints(offsetsBlock), 0, faces + 1);
    }
    final cornerVert = cornerLayers['.corner_vert'];
    if (cornerVert != null && cornerCount > 0) {
      corners = Int32List.sublistView(file.ints(cornerVert), 0, cornerCount);
    }
    final materialLayer = faceLayers['material_index'];
    if (materialLayer != null && faces > 0) {
      materials = file.ints(materialLayer).sublist(0, faces);
    }
    final sharp = faceLayers['sharp_face'];
    if (sharp != null && faces > 0) {
      smooth = [
        for (var f = 0; f < faces; f++) file.bytes[sharp.offset + f] == 0,
      ];
    }

    // MPoly / MLoop (Blender 2.63 – 3.x).
    final mpoly = file.blockAt(mesh.pointer('mpoly'));
    if (faceStarts == null && mpoly != null && faces > 0) {
      faceStarts = Int32List(faces + 1);
      final mats = <int>[];
      final flags = <bool>[];
      for (var f = 0; f < faces; f++) {
        final poly = file.structAs(mpoly, 'MPoly', f);
        if (poly == null) return null;
        faceStarts[f] = poly.integer('loopstart');
        faceStarts[f + 1] = poly.integer('loopstart') + poly.integer('totloop');
        mats.add(poly.integer('mat_nr'));
        flags.add(poly.integer('flag') & 1 != 0);
      }
      materials ??= mats;
      smooth ??= flags;
    }
    final mloop = file.blockAt(mesh.pointer('mloop'));
    if (corners == null && mloop != null && cornerCount > 0) {
      corners = Int32List(cornerCount);
      final type = file.dna.byName['MLoop'];
      final v = type?.fields['v'];
      if (type == null || v == null) return null;
      for (var i = 0; i < cornerCount; i++) {
        corners[i] = file.readInt32(mloop.offset + i * type.size + v.offset);
      }
    }

    // MFace (before 2.63).
    final mface = file.blockAt(mesh.pointer('mface'));
    if ((faceStarts == null || corners == null) && mface != null) {
      faces = _count(['totface']);
      final starts = <int>[0];
      final list = <int>[];
      final mats = <int>[];
      final flags = <bool>[];
      for (var f = 0; f < faces; f++) {
        final face = file.structAs(mface, 'MFace', f);
        if (face == null) break;
        final v4 = face.integer('v4');
        list.addAll([
          face.integer('v1'),
          face.integer('v2'),
          face.integer('v3'),
        ]);
        if (v4 != 0) list.add(v4);
        starts.add(list.length);
        mats.add(face.integer('mat_nr'));
        flags.add(face.integer('flag') & 1 != 0);
      }
      faceStarts = Int32List.fromList(starts);
      corners = Int32List.fromList(list);
      materials = mats;
      smooth = flags;
    }

    if (faceStarts == null || corners == null) return null;
    // Guard against damaged indices.
    for (final c in corners) {
      if (c < 0 || c >= verts) return null;
    }
    if (faceStarts.last > corners.length) return null;
    return _Geometry(positions, faceStarts, corners, materials, smooth);
  }

  Float32List? _legacyPositions(int verts) {
    final mvert = file.blockAt(mesh.pointer('mvert'));
    final type = file.dna.byName['MVert'];
    final co = type?.fields['co'];
    if (mvert == null || type == null || co == null) return null;
    if (mvert.length < verts * type.size) return null;
    final out = Float32List(verts * 3);
    for (var i = 0; i < verts; i++) {
      final at = mvert.offset + i * type.size + co.offset;
      out[i * 3] = file.readFloat(at);
      out[i * 3 + 1] = file.readFloat(at + 4);
      out[i * 3 + 2] = file.readFloat(at + 8);
    }
    return out;
  }

  /// The mesh's material slots (null entries for empty slots).
  static List<BlendStruct?> materials(BlendFile file, BlendStruct mesh) {
    final block = file.blockAt(mesh.pointer('mat'));
    final count = mesh.integer(mesh.pick(['totcol']) ?? 'totcol');
    if (block == null || count <= 0) return const [];
    return [
      for (var i = 0; i < count; i++)
        if ((i + 1) * file.pointerSize <= block.length)
          () {
            final target = file.blockAt(
              file.readPointer(block.offset + i * file.pointerSize),
            );
            final s = target == null ? null : file.structOf(target);
            return s?.type.name == 'Material' ? s : null;
          }(),
    ];
  }
}

/// Column-major 4×4 matrices, as Blender stores them.
abstract final class _Matrix {
  static const identity = [
    1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, //
    0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
  ];

  static List<double> multiply(List<double> a, List<double> b) => [
    for (var c = 0; c < 4; c++)
      for (var r = 0; r < 4; r++)
        a[r] * b[c * 4] +
            a[4 + r] * b[c * 4 + 1] +
            a[8 + r] * b[c * 4 + 2] +
            a[12 + r] * b[c * 4 + 3],
  ];

  /// The object's world matrix: the one saved with it, else computed from
  /// location/rotation/scale and its parents.
  static List<double> world(BlendStruct ob, [int depth = 0]) {
    final saved = ob.floats(ob.pick(['object_to_world', 'obmat']) ?? '');
    if (saved != null && saved.length == 16 && saved[15] != 0) return saved;
    final local = _local(ob);
    final parent = depth < 32 ? ob.follow('parent') : null;
    if (parent == null || parent.type.name != 'Object') return local;
    final inverse = ob.floats('parentinv') ?? identity;
    return multiply(multiply(world(parent, depth + 1), inverse), local);
  }

  static List<double> _local(BlendStruct ob) {
    List<double> vec(String name, double fallback) =>
        ob.floats(name) ?? [fallback, fallback, fallback];
    final loc = vec('loc', 0), dloc = vec('dloc', 0);
    final size = vec('scale', 1).length == 3 && ob.has('scale')
        ? vec('scale', 1)
        : vec('size', 1);
    final dsize = ob.has('dscale') ? vec('dscale', 1) : vec('dsize', 1);
    final mode = ob.has('rotmode') ? ob.integer('rotmode') : 1;
    final rot = _rotation(ob, mode, delta: false);
    final drot = _rotation(ob, mode, delta: true);
    final r = _mul3(drot, rot);
    final s = [size[0] * dsize[0], size[1] * dsize[1], size[2] * dsize[2]];
    return [
      r[0] * s[0], r[1] * s[0], r[2] * s[0], 0, //
      r[3] * s[1], r[4] * s[1], r[5] * s[1], 0,
      r[6] * s[2], r[7] * s[2], r[8] * s[2], 0,
      loc[0] + dloc[0], loc[1] + dloc[1], loc[2] + dloc[2], 1,
    ];
  }

  /// Column-major 3×3 rotation for Blender's rotation modes.
  static List<double> _rotation(
    BlendStruct ob,
    int mode, {
    required bool delta,
  }) {
    String f(String name) => delta ? 'd$name' : name;
    if (mode == 0) {
      final q = ob.floats(f('quat')) ?? [1.0, 0.0, 0.0, 0.0];
      return _quat(q[0], q[1], q[2], q[3]);
    }
    if (mode == -1) {
      final axis = ob.floats(f('rotAxis')) ?? [0.0, 1.0, 0.0];
      final angle = ob.float(f('rotAngle'));
      final len = math.sqrt(
        axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2],
      );
      if (len == 0) return const [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
      final s = math.sin(angle / 2) / len;
      return _quat(math.cos(angle / 2), axis[0] * s, axis[1] * s, axis[2] * s);
    }
    final e = ob.floats(f('rot')) ?? [0.0, 0.0, 0.0];
    const orders = ['XYZ', 'XZY', 'YXZ', 'YZX', 'ZXY', 'ZYX'];
    final order = orders[(mode - 1).clamp(0, 5)];
    var m = const [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
    for (final axis in order.split('')) {
      final angle = e['XYZ'.indexOf(axis)];
      m = _mul3(_axisRotation(axis, angle), m);
    }
    return m;
  }

  static List<double> _axisRotation(String axis, double a) {
    final c = math.cos(a), s = math.sin(a);
    return switch (axis) {
      'X' => [1, 0, 0, 0, c, s, 0, -s, c],
      'Y' => [c, 0, -s, 0, 1, 0, s, 0, c],
      _ => [c, s, 0, -s, c, 0, 0, 0, 1],
    };
  }

  static List<double> _quat(double w, double x, double y, double z) {
    final n = math.sqrt(w * w + x * x + y * y + z * z);
    if (n == 0) return const [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
    w /= n;
    x /= n;
    y /= n;
    z /= n;
    return [
      1 - 2 * (y * y + z * z),
      2 * (x * y + w * z),
      2 * (x * z - w * y),
      2 * (x * y - w * z),
      1 - 2 * (x * x + z * z),
      2 * (y * z + w * x),
      2 * (x * z + w * y),
      2 * (y * z - w * x),
      1 - 2 * (x * x + y * y),
    ];
  }

  static List<double> _mul3(List<double> a, List<double> b) => [
    for (var c = 0; c < 3; c++)
      for (var r = 0; r < 3; r++)
        a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2],
  ];
}

/// Collects meshes and writes a GLB.
class _GltfBuilder {
  final _bin = BytesBuilder();
  final _accessors = <Map<String, Object>>[];
  final _views = <Map<String, Object>>[];
  final _meshes = <Map<String, Object>>[];
  final _nodes = <Map<String, Object>>[];
  final _materials = <Map<String, Object>>[];
  final _materialIndex = <String, int>{};

  int _material(_Material m) {
    final key = '${m.name}|${m.color}|${m.metallic}|${m.roughness}';
    return _materialIndex.putIfAbsent(key, () {
      _materials.add({
        'name': m.name,
        'pbrMetallicRoughness': {
          'baseColorFactor': m.color,
          'metallicFactor': m.metallic,
          'roughnessFactor': m.roughness,
        },
        if (m.color[3] < 1) 'alphaMode': 'BLEND',
        'doubleSided': true,
      });
      return _materials.length - 1;
    });
  }

  int _addView(Uint8List data, {int? target}) {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    final offset = _bin.length;
    _bin.add(data);
    _views.add({
      'buffer': 0,
      'byteOffset': offset,
      'byteLength': data.length,
      'target': ?target,
    });
    return _views.length - 1;
  }

  BlendMeshInfo addObject(
    String name,
    _Geometry g,
    List<double> world,
    List<_Material> materials,
  ) {
    // Normal matrix: inverse transpose of the upper 3×3.
    final m = world;
    final a = m[0], b = m[4], c = m[8];
    final d = m[1], e = m[5], f = m[9];
    final gg = m[2], h = m[6], i = m[10];
    final det =
        a * (e * i - f * h) - b * (d * i - f * gg) + c * (d * h - e * gg);
    final inv = det == 0 ? 0.0 : 1 / det;
    // Rows of the inverse transpose (= cofactor matrix / det).
    final n = [
      (e * i - f * h) * inv,
      -(d * i - f * gg) * inv,
      (d * h - e * gg) * inv,
      -(b * i - c * h) * inv,
      (a * i - c * gg) * inv,
      -(a * h - b * gg) * inv,
      (b * f - c * e) * inv,
      -(a * f - c * d) * inv,
      (a * e - b * d) * inv,
    ];
    final flip = det < 0;

    final pos = g.positions;
    final vertexCount = g.vertexCount;
    // Area-weighted vertex normals (object space) and face normals.
    final vertexNormals = Float32List(vertexCount * 3);
    final faceNormals = Float32List(g.faceCount * 3);
    for (var face = 0; face < g.faceCount; face++) {
      final start = g.faceStarts[face], end = g.faceStarts[face + 1];
      if (end - start < 3) continue;
      double nx = 0, ny = 0, nz = 0;
      for (var k = start; k < end; k++) {
        final p = g.corners[k] * 3;
        final q = g.corners[k + 1 < end ? k + 1 : start] * 3;
        nx += (pos[p + 1] - pos[q + 1]) * (pos[p + 2] + pos[q + 2]);
        ny += (pos[p + 2] - pos[q + 2]) * (pos[p] + pos[q]);
        nz += (pos[p] - pos[q]) * (pos[p + 1] + pos[q + 1]);
      }
      faceNormals[face * 3] = nx;
      faceNormals[face * 3 + 1] = ny;
      faceNormals[face * 3 + 2] = nz;
      for (var k = start; k < end; k++) {
        final v = g.corners[k] * 3;
        vertexNormals[v] += nx;
        vertexNormals[v + 1] += ny;
        vertexNormals[v + 2] += nz;
      }
    }

    final prims = <int, _Primitive>{};
    final min = [double.infinity, double.infinity, double.infinity];
    final max = [
      double.negativeInfinity,
      double.negativeInfinity,
      double.negativeInfinity,
    ];
    var triangles = 0;

    // World position in Blender axes, then glTF's Y-up: (x, z, -y).
    void put(_Primitive prim, int v, double nx, double ny, double nz) {
      final x = pos[v * 3], y = pos[v * 3 + 1], z = pos[v * 3 + 2];
      final wx = m[0] * x + m[4] * y + m[8] * z + m[12];
      final wy = m[1] * x + m[5] * y + m[9] * z + m[13];
      final wz = m[2] * x + m[6] * y + m[10] * z + m[14];
      if (wx < min[0]) min[0] = wx;
      if (wy < min[1]) min[1] = wy;
      if (wz < min[2]) min[2] = wz;
      if (wx > max[0]) max[0] = wx;
      if (wy > max[1]) max[1] = wy;
      if (wz > max[2]) max[2] = wz;
      var tx = n[0] * nx + n[1] * ny + n[2] * nz;
      var ty = n[3] * nx + n[4] * ny + n[5] * nz;
      var tz = n[6] * nx + n[7] * ny + n[8] * nz;
      final len = math.sqrt(tx * tx + ty * ty + tz * tz);
      if (len > 0) {
        tx /= len;
        ty /= len;
        tz /= len;
      } else {
        tz = 1;
      }
      prim.positions.addAll([wx, wz, -wy]);
      prim.normals.addAll([tx, tz, -ty]);
    }

    for (var face = 0; face < g.faceCount; face++) {
      final start = g.faceStarts[face], end = g.faceStarts[face + 1];
      if (end - start < 3) continue;
      final slot = g.materialIndex == null ? 0 : g.materialIndex![face];
      final prim = prims.putIfAbsent(
        materials.isEmpty ? -1 : slot.clamp(0, materials.length - 1),
        _Primitive.new,
      );
      final smooth = g.smooth == null || g.smooth![face];
      final local = <int, int>{};
      int index(int v) {
        if (smooth) {
          return prim.smoothIndex.putIfAbsent(v, () {
            put(
              prim,
              v,
              vertexNormals[v * 3],
              vertexNormals[v * 3 + 1],
              vertexNormals[v * 3 + 2],
            );
            return prim.count++;
          });
        }
        return local.putIfAbsent(v, () {
          put(
            prim,
            v,
            faceNormals[face * 3],
            faceNormals[face * 3 + 1],
            faceNormals[face * 3 + 2],
          );
          return prim.count++;
        });
      }

      final first = index(g.corners[start]);
      for (var k = start + 1; k + 1 < end; k++) {
        final b1 = index(g.corners[k]);
        final b2 = index(g.corners[k + 1]);
        prim.indices.addAll(flip ? [first, b2, b1] : [first, b1, b2]);
        triangles++;
      }
    }

    final primitives = <Map<String, Object>>[];
    for (final MapEntry(key: slot, value: prim) in prims.entries) {
      if (prim.indices.isEmpty) continue;
      final positions = Float32List.fromList(prim.positions);
      final normals = Float32List.fromList(prim.normals);
      final pMin = [double.infinity, double.infinity, double.infinity];
      final pMax = [
        double.negativeInfinity,
        double.negativeInfinity,
        double.negativeInfinity,
      ];
      for (var k = 0; k < positions.length; k++) {
        final axis = k % 3;
        if (positions[k] < pMin[axis]) pMin[axis] = positions[k];
        if (positions[k] > pMax[axis]) pMax[axis] = positions[k];
      }
      final posView = _addView(positions.buffer.asUint8List(), target: 34962);
      _accessors.add({
        'bufferView': posView,
        'componentType': 5126,
        'count': prim.count,
        'type': 'VEC3',
        'min': pMin,
        'max': pMax,
      });
      final posAccessor = _accessors.length - 1;
      final normView = _addView(normals.buffer.asUint8List(), target: 34962);
      _accessors.add({
        'bufferView': normView,
        'componentType': 5126,
        'count': prim.count,
        'type': 'VEC3',
      });
      final normAccessor = _accessors.length - 1;
      final indices = Uint32List.fromList(prim.indices);
      final indexView = _addView(indices.buffer.asUint8List(), target: 34963);
      _accessors.add({
        'bufferView': indexView,
        'componentType': 5125,
        'count': indices.length,
        'type': 'SCALAR',
      });
      primitives.add({
        'attributes': {'POSITION': posAccessor, 'NORMAL': normAccessor},
        'indices': _accessors.length - 1,
        'material': _material(slot < 0 ? _Material.fallback : materials[slot]),
      });
    }
    if (primitives.isNotEmpty) {
      _meshes.add({'name': name, 'primitives': primitives});
      _nodes.add({'name': name, 'mesh': _meshes.length - 1});
    }
    return BlendMeshInfo(name, triangles, min, max);
  }

  Uint8List encode() {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    final bin = _bin.takeBytes();
    final json = utf8.encode(
      jsonEncode({
        'asset': {'version': '2.0', 'generator': 'Folder .blend reader'},
        'scene': 0,
        'scenes': [
          {
            'nodes': [for (var i = 0; i < _nodes.length; i++) i],
          },
        ],
        'nodes': _nodes,
        'meshes': _meshes,
        'materials': _materials,
        'accessors': _accessors,
        'bufferViews': _views,
        'buffers': [
          {'byteLength': bin.length},
        ],
      }),
    );
    final jsonPadded = (json.length + 3) & ~3;
    final total = 12 + 8 + jsonPadded + 8 + bin.length;
    final out = Uint8List(total);
    final view = ByteData.sublistView(out);
    view
      ..setUint32(0, 0x46546C67, Endian.little) // glTF
      ..setUint32(4, 2, Endian.little)
      ..setUint32(8, total, Endian.little)
      ..setUint32(12, jsonPadded, Endian.little)
      ..setUint32(16, 0x4E4F534A, Endian.little); // JSON
    out.setRange(20, 20 + json.length, json);
    out.fillRange(20 + json.length, 20 + jsonPadded, 0x20);
    final binStart = 20 + jsonPadded;
    view
      ..setUint32(binStart, bin.length, Endian.little)
      ..setUint32(binStart + 4, 0x004E4942, Endian.little); // BIN
    out.setRange(binStart + 8, total, bin);
    return out;
  }
}

class _Primitive {
  final positions = <double>[];
  final normals = <double>[];
  final indices = <int>[];
  final smoothIndex = <int, int>{};
  int count = 0;
}
