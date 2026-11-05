final _searchSpaces = RegExp(r'\s+');

String normalizeCatalogSearch(String value) =>
    value.toLowerCase().replaceAll('ё', 'е');

List<String> catalogSearchTerms(String value) {
  final normalized = normalizeCatalogSearch(value).trim();
  return normalized.isEmpty ? const [] : normalized.split(_searchSpaces);
}

bool matchesCatalogSearch(String text, List<String> terms) {
  final haystack = normalizeCatalogSearch(text);
  return terms.every(haystack.contains);
}
