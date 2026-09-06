import 'package:flutter_test/flutter_test.dart';

import '../../tool/verify_web_shader_bundle.dart';

const String _generatedDepthBlock = '''
gl_Position.z = (_sky.w * 0.999999f);
gl_Position.z = (_flash.w * 0.0000005f);
gl_Position.z = (_weapon.w * 0.000001f);
gl_Position.z = ((_clip.z + _clipW.w) * 0.5f);
''';

void main() {
  test('accepts ordered pins followed by semantic WebGPU depth remap', () {
    expect(webVertexDepthContractError(_generatedDepthBlock), isNull);
  });

  test('rejects a formatting lookalike without z-plus-w remapping', () {
    final vertex = _generatedDepthBlock.replaceFirst(
      '((_clip.z + _clipW.w) * 0.5f)',
      '(_clip.z * 0.5f)',
    );

    expect(
      webVertexDepthContractError(vertex),
      'GL-to-WebGPU depth remap is missing',
    );
  });

  test('rejects missing or negative authored depth pins', () {
    expect(
      webVertexDepthContractError(
        _generatedDepthBlock.replaceFirst(
          '(_weapon.w * 0.000001f)',
          '-(_weapon.w * 0.000001f)',
        ),
      ),
      'first-person weapon depth pin is missing',
    );
    expect(
      webVertexDepthContractError(
        _generatedDepthBlock.replaceFirst(
          '(_weapon.w * 0.000001f)',
          '(-(_weapon.w) * 0.000001f)',
        ),
      ),
      'first-person weapon depth pin is missing',
    );
    expect(
      webVertexDepthContractError(
        _generatedDepthBlock.replaceFirst(
          'gl_Position.z = (_flash.w * 0.0000005f);\n',
          '',
        ),
      ),
      'expected three depth pins followed by the WebGPU depth remap',
    );
  });
}
