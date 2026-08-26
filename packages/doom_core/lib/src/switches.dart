/// Which texture field on a sidedef carries a switch face.
enum SwitchTextureSlot { upper, middle, lower }

/// Retained renderer output describing one visual switch mutation.
class SwitchTextureChange {
  const SwitchTextureChange({
    required this.linedef,
    required this.sidedef,
    required this.slot,
    required this.textureName,
    required this.tic,
  });

  final int linedef;
  final int sidedef;
  final SwitchTextureSlot slot;
  final String textureName;
  final int tic;
}
