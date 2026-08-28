// Pure helpers for Main.qml / ThemeCard.qml. No QML state lives here so
// these stay trivially testable and easy to reason about.

// SPEC §49: active theme first, then user-installed themes, then
// alphabetical. Discovery already returns rows sorted user-before-system,
// then alphabetical, so this only has to move the active theme (if any) to
// the front without disturbing the rest of that order.
function sortThemes(themes, activeId) {
  var list = Array.isArray(themes) ? themes.slice() : []
  if (!activeId) return list

  var activeIndex = -1
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === activeId) { activeIndex = i; break }
  }
  if (activeIndex <= 0) return list

  var active = list[activeIndex]
  list.splice(activeIndex, 1)
  list.unshift(active)
  return list
}

function parseJsonArray(text) {
  try {
    var parsed = JSON.parse(text || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

function parseJsonObject(text) {
  try {
    var parsed = JSON.parse(text || "{}")
    return (parsed && typeof parsed === "object") ? parsed : {}
  } catch (e) {
    return {}
  }
}

// Responsive column count. SPEC §26: large -> 4, medium -> 3, small -> 2.
// Thresholds are tuned so a card never drops below ~170px wide at 3-4
// columns before the layout steps down to fewer, wider columns instead.
function columnsForWidth(width) {
  if (width >= 760) return 4
  if (width >= 560) return 3
  return 2
}
