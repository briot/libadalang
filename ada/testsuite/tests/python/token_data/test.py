from __future__ import absolute_import, division, print_function

import libadalang


ctx = libadalang.AnalysisContext()
u = ctx.get_from_file('foo.adb')
node = u.root.find(libadalang.Identifier)
t = node.f_tok

print('Token data for the "foo" identifier:')
print('Kind: {}'.format(t.kind))
print('Text: {}'.format(t.text))
print('Sloc range: {}'.format(t.sloc_range))
print('Done.')
