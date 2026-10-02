"""Interpret Go test events independently of toolchains and source checkout."""

import json


def read_events(path):
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def failed_tests(events):
    return sorted({(event['Package'], event['Test']) for event in events
                   if event.get('Action') == 'fail' and 'Test' in event})


def verify_events(path, expected):
    events = read_events(path)
    passed = {(event['Package'], event['Test']) for event in events
              if event.get('Action') == 'pass' and 'Test' in event}
    rejected = {(event['Package'], event.get('Test')) for event in events
                if event.get('Action') in ('fail', 'skip')}
    missing = sorted(expected - passed)
    if missing or rejected:
        raise ValueError(f'Core contracts missing, skipped or failed: {missing}; '
                         f'rejected events: {sorted(rejected, key=str)}')
    return len(expected)
