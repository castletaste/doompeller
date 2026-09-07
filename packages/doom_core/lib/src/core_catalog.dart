import 'actor_catalog.dart' as actors;
import 'mobj_info.dart';
import 'special_dispatch.dart' as specials;
import 'config.dart';

abstract final class DoomCoreCatalog {
  static Set<int> get supportedLinedefSpecials =>
      specials.supportedLineSpecials;
  static Set<int> get supportedSectorSpecials =>
      specials.supportedSectorSpecials;
  static Set<String> get soundIds => specials.coreSoundIds;

  static MobjInfo? infoForEdNum(int doomEdNum) =>
      actors.infoForEdNum(doomEdNum);

  static Key? requiredKeyForLineSpecial(int special) =>
      specials.requiredKey(special);

  static Key? keyForEdNum(int doomEdNum) {
    final MobjInfo? info = actors.infoForEdNum(doomEdNum);
    return info == null ? null : specials.keyForMobjType(info.id);
  }
}
