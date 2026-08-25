import 'game_state.dart';
import 'ticcmd.dart';

class CommandReplay {
  CommandReplay({required this.seed, required this.commands});
  final int seed;
  final List<TicCmd> commands;

  List<int> run(GameState state) {
    final List<int> hashes = <int>[];
    for (final TicCmd command in commands) {
      state.runTic(command);
      hashes.add(state.hashState());
    }
    return hashes;
  }
}
