import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';
import 'package:ssrvpn_shared/services/subscription_yaml_merger.dart';

int _resultChecksum = 0;

void main(List<String> arguments) {
  final smoke = arguments.contains('--smoke');
  final verify = arguments.contains('--verify');
  final nodeCount = smoke ? 240 : 1200;
  final iterations = smoke ? 2 : 7;
  const sourceCount = 4;

  final fixture = _yamlFixture(0, nodeCount);
  final sources = List.generate(
    sourceCount,
    (index) => _yamlFixture(index * nodeCount, nodeCount),
  );
  final sourceNames =
      List.generate(sourceCount, (index) => 'Source ${index + 1}');
  final merged = SubscriptionYamlMerger.mergeYamlConfigs(
    sources,
    sourceNames: sourceNames,
  );
  final settings = AppSettings(
    proxyPort: 7890,
    socksPort: 7891,
    apiPort: 9090,
  );

  final results = <String, Map<String, Object>>{
    'parse_yaml': _measure(
      iterations,
      () => SubscriptionParser.parseYaml(fixture),
    ),
    'merge_yaml': _measure(
      iterations,
      () => SubscriptionYamlMerger.mergeYamlConfigs(
        sources,
        sourceNames: sourceNames,
      ),
    ),
    'generate_config': _measure(
      iterations,
      () => ClashConfigGenerator.generateConfig(merged, settings),
    ),
  };

  final mergedNodeCount = ClashConfigGenerator.extractProxyNames(merged).length;
  final generated = ClashConfigGenerator.generateConfig(merged, settings);
  final expectedMergedNodes = nodeCount * sourceCount;
  if (verify &&
      (mergedNodeCount != expectedMergedNodes ||
          !generated.contains('proxy-groups:') ||
          results.values.any((result) => (result['median_us'] as int) < 0))) {
    throw StateError('Critical-path benchmark produced invalid output');
  }

  final report = <String, Object>{
    'schema_version': 1,
    'mode': smoke ? 'smoke' : 'baseline',
    'fixture': {
      'nodes_per_source': nodeCount,
      'source_count': sourceCount,
      'merged_nodes': mergedNodeCount,
      'merged_bytes': utf8.encode(merged).length,
      'generated_config_bytes': utf8.encode(generated).length,
    },
    'results': results,
    'notes': [
      'Durations are observational and are not pass/fail thresholds.',
      'Compare results only on comparable hardware and Flutter versions.',
    ],
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}

Map<String, Object> _measure(int iterations, Object? Function() operation) {
  operation();
  final samples = <int>[];
  for (var i = 0; i < iterations; i++) {
    final watch = Stopwatch()..start();
    final result = operation();
    _resultChecksum = Object.hash(_resultChecksum, result);
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return {
    'iterations': iterations,
    'min_us': samples.first,
    'median_us': samples[samples.length ~/ 2],
    'max_us': samples.last,
  };
}

String _yamlFixture(int start, int count) {
  final buffer = StringBuffer('proxies:\n');
  for (var offset = 0; offset < count; offset++) {
    final index = start + offset;
    final hostOctet = (index % 250) + 1;
    buffer.writeln(
      '  - {"name":"Node $index","type":"ss",'
      '"server":"192.0.2.$hostOctet","port":443,'
      '"cipher":"aes-128-gcm","password":"fixture"}',
    );
  }
  return buffer.toString();
}
