import 'dart:convert';
import 'dart:io';

Never _fail(String message) {
  stderr.writeln('error: invalid WebGPU shader bundle: $message');
  exit(1);
}

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('usage: dart run tool/verify_web_shader_bundle.dart <file>');
    exit(2);
  }
  final file = File(arguments.single);
  if (!file.existsSync()) _fail('file does not exist');
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) _fail('root is not an object');
  final vertex = decoded['vertex'];
  final fragment = decoded['fragment'];
  final slots = decoded['slots'];
  if (vertex is! String || fragment is! String) {
    _fail('vertex or fragment WGSL is missing');
  }
  if (slots is! Map<String, Object?>) _fail('reflection slots are missing');

  const inputSignature =
      'fn main(@location(0) vertexPosition: vec3<f32>, '
      '@location(1) vertexTexCoord: vec2<f32>, '
      '@location(2) vertexColor: vec4<f32>, '
      '@location(3) vertexNormal: vec3<f32>, '
      '@location(4) vertexJoints: vec4<f32>, '
      '@location(5) vertexWeights: vec4<f32>) -> VertexOutput {';
  if (!vertex.contains(inputSignature)) {
    _fail('the exact 20-float vertex input signature is missing');
  }
  final depthError = webVertexDepthContractError(vertex);
  if (depthError != null) _fail(depthError);
  if (!fragment.contains('@fragment')) _fail('fragment entry point is missing');

  _expectUniform(
    slots,
    'VertexInfo',
    group: 0,
    binding: 0,
    size: 192,
    offsets: const <String, int>{'model': 0, 'view': 64, 'projection': 128},
  );
  _expectUniform(
    slots,
    'DoomMaterial',
    group: 1,
    binding: 6,
    size: 48,
    offsets: const <String, int>{'atlasSize': 0, 'palette': 16, 'lighting': 32},
  );
  _expectTexture(slots, 'indexAtlas', binding: 0, samplerBinding: 1);
  _expectTexture(slots, 'colorMapLut', binding: 2, samplerBinding: 3);
  _expectTexture(slots, 'paletteLut', binding: 4, samplerBinding: 5);
  stdout.writeln(
    'WebGPU shader ABI verified: 6 vertex locations, 192/48-byte uniforms',
  );
}

/// Returns an error when generated WGSL no longer preserves Doompeller's
/// ordered sky/weapon/flash depth pins and the required GL-to-WebGPU remap.
///
/// flame_3d appends the final remap because vector_math projection matrices
/// produce GL's -1..1 clip depth while WebGPU accepts 0..1. The three authored
/// pins precede that generated assignment. Match their semantics rather than
/// compiler-generated temporary names.
String? webVertexDepthContractError(String vertex) {
  final depthWrites = vertex
      .split('\n')
      .where((line) => line.contains('gl_Position.z ='))
      .toList(growable: false);
  if (depthWrites.length != 4) {
    return 'expected three depth pins followed by the WebGPU depth remap';
  }

  bool hasPositiveWPin(String literal) {
    final factor = RegExp(
      r'^\s*gl_Position\.z\s*=\s*\(\s*\w+\.w\s*\*\s*' +
          RegExp.escape(literal) +
          r'\s*\);\s*$',
    );
    return depthWrites.where(factor.hasMatch).length == 1;
  }

  if (!hasPositiveWPin('0.999999f')) {
    return 'far-plane sky depth pin is missing';
  }
  if (!hasPositiveWPin('0.0000005f')) {
    return 'frontmost muzzle-flash depth pin is missing';
  }
  if (!hasPositiveWPin('0.000001f')) {
    return 'first-person weapon depth pin is missing';
  }

  final remap = RegExp(
    r'gl_Position\.z\s*=\s*\(\([^;]+\.z\s*\+\s*[^;]+\.w\)\s*\*\s*0\.5f\);',
  );
  if (!remap.hasMatch(depthWrites.last)) {
    return 'GL-to-WebGPU depth remap is missing';
  }
  return null;
}

void _expectUniform(
  Map<String, Object?> slots,
  String name, {
  required int group,
  required int binding,
  required int size,
  required Map<String, int> offsets,
}) {
  final value = slots[name];
  if (value is! Map<String, Object?>) _fail('$name reflection is missing');
  if (value['group'] != group || value['binding'] != binding) {
    _fail(
      '$name is group/binding ${value['group']}/${value['binding']}, '
      'expected $group/$binding',
    );
  }
  if (value['sizeInBytes'] != size) {
    _fail('$name size is ${value['sizeInBytes']}, expected $size');
  }
  final members = value['memberOffsets'];
  if (members is! Map<String, Object?>) {
    _fail('$name member offsets are missing');
  }
  for (final entry in offsets.entries) {
    if (members[entry.key] != entry.value) {
      _fail(
        '$name.${entry.key} is ${members[entry.key]}, expected ${entry.value}',
      );
    }
  }
}

void _expectTexture(
  Map<String, Object?> slots,
  String name, {
  required int binding,
  required int samplerBinding,
}) {
  final value = slots[name];
  if (value is! Map<String, Object?>) _fail('$name reflection is missing');
  if (value['group'] != 1 ||
      value['binding'] != binding ||
      value['samplerBinding'] != samplerBinding) {
    _fail(
      '$name bindings are ${value['group']}/${value['binding']}/'
      '${value['samplerBinding']}, expected 1/$binding/$samplerBinding',
    );
  }
}
