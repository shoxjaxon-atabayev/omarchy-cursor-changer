#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const Model = requireFromRoot('CursorChangerModel.js')

// --- sortThemes: active-first, otherwise order preserved -----------------
const themes = [
  { id: 'UserOnly', source: 'user' },
  { id: 'Shared', source: 'user' },
  { id: 'Adwaita', source: 'system' },
  { id: 'Yaru', source: 'system' },
]

assertDeepEqual(
  Model.sortThemes(themes, 'Yaru').map(t => t.id),
  ['Yaru', 'UserOnly', 'Shared', 'Adwaita'],
  'sortThemes moves the active theme to the front'
)

assertDeepEqual(
  Model.sortThemes(themes, 'UserOnly').map(t => t.id),
  themes.map(t => t.id),
  'sortThemes is a no-op when the active theme is already first'
)

assertDeepEqual(
  Model.sortThemes(themes, '').map(t => t.id),
  themes.map(t => t.id),
  'sortThemes leaves order untouched when there is no active theme'
)

assertDeepEqual(
  Model.sortThemes(themes, 'DoesNotExist').map(t => t.id),
  themes.map(t => t.id),
  'sortThemes leaves order untouched when the active theme id is not in the list'
)

assertDeepEqual(
  Model.sortThemes([], 'Anything'),
  [],
  'sortThemes handles an empty theme list'
)

assertDeepEqual(
  Model.sortThemes(null, 'Anything'),
  [],
  'sortThemes handles a non-array input defensively'
)

// --- parseJsonArray / parseJsonObject: never throw on bad input ----------
assertDeepEqual(Model.parseJsonArray('[{"id":"A"}]'), [{ id: 'A' }], 'parseJsonArray parses a valid array')
assertDeepEqual(Model.parseJsonArray(''), [], 'parseJsonArray treats empty input as an empty array')
assertDeepEqual(Model.parseJsonArray('not json'), [], 'parseJsonArray recovers from invalid JSON')
assertDeepEqual(Model.parseJsonArray('{"not":"an array"}'), [], 'parseJsonArray rejects a JSON object')

assertDeepEqual(Model.parseJsonObject('{"theme":"Adwaita"}'), { theme: 'Adwaita' }, 'parseJsonObject parses a valid object')
assertDeepEqual(Model.parseJsonObject(''), {}, 'parseJsonObject treats empty input as an empty object')
assertDeepEqual(Model.parseJsonObject('not json'), {}, 'parseJsonObject recovers from invalid JSON')
assertDeepEqual(Model.parseJsonObject('[1,2,3]'), {}, 'parseJsonObject rejects a JSON array')
assertDeepEqual(Model.parseJsonObject('null'), {}, 'parseJsonObject rejects JSON null')

// --- columnsForWidth: SPEC §26 breakpoints --------------------------------
assertEqual(Model.columnsForWidth(1200), 4, 'columnsForWidth: large window -> 4 columns')
assertEqual(Model.columnsForWidth(760), 4, 'columnsForWidth: exactly the large breakpoint -> 4 columns')
assertEqual(Model.columnsForWidth(700), 3, 'columnsForWidth: medium window -> 3 columns')
assertEqual(Model.columnsForWidth(560), 3, 'columnsForWidth: exactly the medium breakpoint -> 3 columns')
assertEqual(Model.columnsForWidth(400), 2, 'columnsForWidth: small window -> 2 columns')
assertEqual(Model.columnsForWidth(0), 2, 'columnsForWidth: never drops below 2 columns')

console.log('All model tests passed.')
JS
