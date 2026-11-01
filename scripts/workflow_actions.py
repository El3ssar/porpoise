"""Literal external-action references in block and flow-style GitHub Actions YAML."""
import re


def references(text):
    result = []
    key = r'(?:uses|[\'"]uses[\'"])\s*:'
    for line in text.splitlines():
        source, _, comment = line.partition('#')
        if (re.search(r'\\(?:x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8})', source)
                or re.search(r'(?:^\s*(?:-\s*)?|[{,]\s*)(?:[!&][^\s]+\s+)*\?\s', source)):
            raise ValueError('Escaped/explicit YAML mapping keys are unsupported for action pin review')
        matches = list(re.finditer(r'(?:^\s*(?:-\s*)?|' + r'[{,]\s*)' + key + r'\s*([^\s,}]+)', source))
        if re.search(r'(?:^\s*(?:-\s*)?|[{,]\s*)' + key, source) and not matches:
            raise ValueError('Unsupported uses syntax; declare an immutable literal action reference')
        if len(re.findall(key, source)) != len(matches):
            raise ValueError('Unsupported uses syntax; declare an immutable literal action reference')
        for match in matches:
            reference = match[1].strip('\'"')
            if not reference.startswith('./'):
                result.append((reference, comment))
    return result
