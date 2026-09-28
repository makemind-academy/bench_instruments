import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';

import 'package:mcp_server/mcp_server.dart';

import 'serve_bundle.dart';

/// bench_server — three instruments, one screen.
///
/// The instruments already speak. SCPI is not something this server invents;
/// it is something the boxes on the bench have spoken for thirty years. What
/// this server does is wrap those commands in names a person can read, and
/// normalise three vendors' three ways of answering into one shape.
///
/// The normalising is the whole job, and it happens in exactly one function
/// per instrument — [_Instrument.number]. Anywhere else and the next vendor
/// adds a branch somewhere nobody remembers.
void main(List<String> args) async {
  final link = await _Bench.open();
  const config = McpServerConfig(
    name: 'Bench',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(listChanged: true),
      resources: ResourcesCapability(listChanged: true),
    ),
  );
  final server = McpServer.createServer(config);
  BenchServer(server, link).register();
  // The screen next door: AppPlayer reads it from here and sends the pages'
  // tool calls back to the tools above.
  registerBundleUi(server, '../bench.mbd');
  final transport = McpServer.createStdioTransport().get();
  server.connect(transport);
  await Completer<void>().future;
}

/// One box on the bench, and the one place that knows how it answers.
class _Instrument {
  const _Instrument(this.id, this.vendor, this.reply);

  final String id;
  final String vendor;

  /// How this vendor writes a number. Three boxes, three habits.
  final double Function(String raw) reply;

  /// `+3.30000E+00` — exponent notation. Dart parses it directly.
  static double exponent(String raw) => double.parse(raw.trim());

  /// `0.4125\r\n` — plain, but with a carriage return that will silently
  /// break a naive parse if it is not trimmed.
  static double plain(String raw) => double.parse(raw.trim());

  /// `24.8 C` — the unit is glued to the value. Split it off, and keep the
  /// unit out of the number rather than out of the record.
  static double withUnit(String raw) => double.parse(raw.trim().split(' ').first);
}

/// The stdio link to the instruments (the host side of a VISA session).
///
/// Lines are split on the newline only, deliberately. Dart's LineSplitter
/// would swallow a vendor's carriage return before this code ever sees it,
/// and then the one place that is supposed to know about that vendor's habit
/// would never be exercised. Terminators are a property of the instrument, so
/// they arrive intact and get dealt with once.
class _Bench {
  _Bench(this._proc, this._lines);

  final Process _proc;
  final StreamQueue<String> _lines;

  static Future<_Bench> open() async {
    final p = await Process.start('./instruments', const [],
        workingDirectory: '../instruments');
    p.stderr.drain<void>();
    final lines = p.stdout
        .transform(utf8.decoder)
        .transform(const _NewlineOnlySplitter());
    return _Bench(p, StreamQueue(lines));
  }

  /// Write one command, read one line. A bench link is strictly request and
  /// response — nothing arrives that was not asked for.
  Future<String> ask(String who, String cmd) async {
    _proc.stdin.writeln('$who:$cmd');
    return await _lines.next;
  }
}

/// Splits on '\n' and leaves everything else — including '\r' — in place.
class _NewlineOnlySplitter extends StreamTransformerBase<String, String> {
  const _NewlineOnlySplitter();

  @override
  Stream<String> bind(Stream<String> stream) async* {
    var buf = '';
    await for (final chunk in stream) {
      buf += chunk;
      var i = buf.indexOf('\n');
      while (i >= 0) {
        yield buf.substring(0, i);
        buf = buf.substring(i + 1);
        i = buf.indexOf('\n');
      }
    }
    if (buf.isNotEmpty) yield buf;
  }
}

class BenchServer {
  BenchServer(this.server, this.bench);

  final Server server;
  final _Bench bench;

  static const _psu = _Instrument('psu1', 'VENDOR-A', _Instrument.exponent);
  static const _dmm = _Instrument('dmm1', 'VENDOR-B', _Instrument.plain);
  static const _tmp = _Instrument('temp1', 'VENDOR-C', _Instrument.withUnit);

  final _raw = <String, String>{}; // what each box last said, verbatim

  Future<double> _read(_Instrument inst, String cmd) async {
    final raw = await bench.ask(inst.id, cmd);
    _raw['${inst.id}:$cmd'] = raw.replaceAll('\r', r'\r');
    return inst.reply(raw);
  }

  void register() {
    server.addTool(
      name: 'bench.read',
      description: 'Read all three instruments once',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async => _state(await _sweep()),
    );

    server.addTool(
      name: 'psu.set',
      description: 'Set the supply output voltage, in volts',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'volts': {'type': 'number'},
        },
        'required': ['volts'],
      },
      handler: (args) async {
        final v = (args['volts'] as num).toDouble();
        await bench.ask(_psu.id, 'SOUR:VOLT $v');
        return _state(await _sweep(), notice: 'asked the supply for ${v}V');
      },
    );

    server.addTool(
      name: 'psu.output',
      description: 'Turn the supply output on or off',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'on': {'type': 'boolean'},
        },
        'required': ['on'],
      },
      handler: (args) async {
        final on = args['on'] as bool;
        await bench.ask(_psu.id, on ? 'OUTP ON' : 'OUTP OFF');
        return _state(await _sweep(), notice: on ? 'output on' : 'output off');
      },
    );

    server.addTool(
      name: 'bench.identify',
      description: 'Ask every instrument who it is (*IDN?)',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        final who = <String>[];
        for (final i in [_psu, _dmm, _tmp]) {
          who.add((await bench.ask(i.id, '*IDN?')).trim());
        }
        return CallToolResult(content: [TextContent(text: jsonEncode({'idn': who}))]);
      },
    );
  }

  Future<Map<String, double>> _sweep() async => {
        'volts': await _read(_psu, 'MEAS:VOLT?'),
        'amps': await _read(_dmm, 'MEAS:CURR?'),
        'celsius': await _read(_tmp, 'MEAS:TEMP?'),
      };

  CallToolResult _state(Map<String, double> m, {String notice = ''}) {
    final w = m['volts']! * m['amps']!;
    // The limit is the bench's, not the instrument's. A box does not know what
    // the experiment considers too hot.
    const tempLimit = 45.0;
    return CallToolResult(content: [
      TextContent(
        text: jsonEncode({
          'volts': m['volts']!.toStringAsFixed(3),
          'amps': m['amps']!.toStringAsFixed(4),
          'celsius': m['celsius']!.toStringAsFixed(1),
          'watts': w.toStringAsFixed(2),
          'over': m['celsius']! > tempLimit,
          'limitNote': m['celsius']! > tempLimit
              ? 'over the bench limit of $tempLimit C'
              : 'bench limit $tempLimit C',
          'raw': _raw.entries.map((e) => '${e.key} -> ${e.value}').join('  |  '),
          // The bench's own rule. The limit is not the instrument's: a box
          // does not know what this experiment considers too hot.
          'benchRule': 'The limit belongs to the bench · every reading below '
              'is the instrument\'s own answer, verbatim',
          'notice': notice,
        }),
      )
    ]);
  }
}
