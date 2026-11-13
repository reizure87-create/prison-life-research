import sys

def tokenize(src):
    tokens = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n\f\v':
            j = i + 1
            while j < n and src[j] in ' \t\r\n\f\v':
                j += 1
            tokens.append(('WS', src[i:j]))
            i = j
        elif c == '-' and i + 1 < n and src[i+1] == '-':
            if i + 2 < n and src[i+2] == '[':
                k = i + 3
                while k < n and src[k] == '=':
                    k += 1
                if k < n and src[k] == '[':
                    eq = k - (i + 3)
                    end_tag = ']' + '=' * eq + ']'
                    end_idx = src.find(end_tag, k + 1)
                    if end_idx == -1:
                        tokens.append(('COMMENT', src[i:]))
                        i = n
                    else:
                        tokens.append(('COMMENT', src[i:end_idx + len(end_tag)]))
                        i = end_idx + len(end_tag)
                    continue
            nl = src.find('\n', i + 2)
            if nl == -1:
                tokens.append(('COMMENT', src[i:]))
                i = n
            else:
                tokens.append(('COMMENT', src[i:nl]))
                i = nl
        elif c == '[':
            k = i + 1
            while k < n and src[k] == '=':
                k += 1
            if k < n and src[k] == '[':
                eq = k - (i + 1)
                end_tag = ']' + '=' * eq + ']'
                end_idx = src.find(end_tag, k + 1)
                if end_idx == -1:
                    tokens.append(('STR', src[i:]))
                    i = n
                else:
                    tokens.append(('STR', src[i:end_idx + len(end_tag)]))
                    i = end_idx + len(end_tag)
                continue
            tokens.append(('SYM', '['))
            i += 1
        elif c in ('"', "'"):
            q = c
            j = i + 1
            while j < n:
                ch = src[j]
                if ch == '\\':
                    j += 2
                elif ch == q:
                    j += 1
                    break
                else:
                    j += 1
            tokens.append(('STR', src[i:j]))
            i = j
        elif c.isalpha() or c == '_':
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == '_'):
                j += 1
            word = src[i:j]
            kind = 'KW' if word in (
                'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
                'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
                'return', 'then', 'true', 'until', 'while'
            ) else 'ID'
            tokens.append((kind, word))
            i = j
        elif c.isdigit() or (c == '.' and i + 1 < n and src[i+1].isdigit()):
            j = i + 1
            if c == '0' and j < n and src[j] in 'xXbB':
                j += 1
                while j < n and (src[j] in '0123456789abcdefABCDEF_'):
                    j += 1
            else:
                while j < n and (src[j].isdigit() or src[j] in '._eE'):
                    if src[j] in 'eE' and j + 1 < n and src[j+1] in '+-':
                        j += 2
                    else:
                        j += 1
            tokens.append(('NUM', src[i:j]))
            i = j
        elif src[i:i+3] in ('...', '//=', '..='):
            tokens.append(('SYM', src[i:i+3]))
            i += 3
        elif src[i:i+2] in ('//', '+=', '-=', '*=', '/=', '%=', '^=', '..', '==', '~=', '<=', '>=', '::'):
            tokens.append(('SYM', src[i:i+2]))
            i += 2
        else:
            tokens.append(('SYM', c))
            i += 1
    return tokens

def convert_luau_to_luajit(src):
    tokens = tokenize(src)
    # 1. Strip binary 0b... literals -> decimal, underscore separators 1_000 -> 1000
    cleaned = []
    for k, v in tokens:
        if k == 'NUM':
            v2 = v.replace('_', '')
            if v2.startswith(('0b', '0B')):
                v2 = str(int(v2[2:], 2))
            v = v2
        cleaned.append((k, v))
    tokens = cleaned

    # Filter out WS/COMMENT? Keeping comments stripped makes parsing ultra clean and fast, strings untouched!
    # Keep a single space between adjacent ID/KW/NUM tokens when emitting.
    sig = [(k, v) for k, v in tokens if k not in ('WS', 'COMMENT')]

    # Identify expression-if vs statement-if on sig tokens:
    expr_prev_syms = {'=', ',', '(', '[', '{', '+', '-', '*', '//', '/', '%', '^', '..', '==', '~=', '<', '>', '<=', '>='}
    expr_prev_kws = {'return', 'and', 'or', 'not'}

    expr_if_indices = set()
    # Wait: inside (...), statements can only exist inside `function(...) ... end`!
    # Track block stack: STMT_IF, EXPR_IF, LOOP, REPEAT, FUNC, DO
    block_stack = []
    prev_tok = None
    for idx, (k, v) in enumerate(sig):
        if k == 'KW':
            if v == 'if':
                is_expr = False
                if prev_tok is not None:
                    pk, pv = prev_tok
                    if (pk == 'SYM' and pv in expr_prev_syms) or (pk == 'KW' and pv in expr_prev_kws):
                        is_expr = True
                    elif pk == 'KW' and pv in ('then', 'else', 'elseif'):
                        if block_stack and block_stack[-1] == 'EXPR_IF':
                            is_expr = True
                if is_expr:
                    expr_if_indices.add(idx)
                    block_stack.append('EXPR_IF')
                else:
                    block_stack.append('STMT_IF')
            elif v in ('for', 'while'):
                block_stack.append('LOOP')
            elif v == 'repeat':
                block_stack.append('REPEAT')
            elif v == 'function':
                block_stack.append('FUNC')
            elif v == 'do':
                if block_stack and block_stack[-1] == 'LOOP':
                    pass
                else:
                    block_stack.append('DO')
            elif v in ('then', 'elseif', 'else'):
                if block_stack and block_stack[-1] == 'EXPR_IF':
                    expr_if_indices.add(idx)
            elif v == 'end':
                # Note: an unclosed EXPR_IF doesn't have an 'end'; pop any EXPR_IFs first!
                while block_stack and block_stack[-1] == 'EXPR_IF':
                    block_stack.pop()
                if block_stack:
                    block_stack.pop()
            elif v == 'until':
                while block_stack and block_stack[-1] == 'EXPR_IF':
                    block_stack.pop()
                if block_stack and block_stack[-1] == 'REPEAT':
                    block_stack.pop()
        elif k == 'SYM' and v in (';', ',', ')', ']', '}'):
            # Pop EXPR_IFs ONLY if bracket depth matches? Wait: brackets inside EXPR_IF are balanced before closing enclosing ')'!
            pass
        prev_tok = (k, v)

    # Better yet: do recursive-descent expression-if & `//` & compound-assign parsing directly on `sig`!
    # Wait: let's track bracket depth properly when finding expr-if tokens!
    expr_if_starts = set()
    # Actually let's parse with explicit bracket + block stack to find exact extent of EVERY expression-if!
    # Wait: why is an explicit bracket + block stack needed? Suppose we have:
    # `local x = if (if a then 1 else 2) == 1 then 3 else 4;`
    # Inside `( ... )`, the inner `if` stops at `)`!
    # Suppose we have: `for ... do ... end` inside an anonymous `function()` inside an expression!
    # With a recursive expression parser for expr-ifs & // & compound ops, or even simpler:
    # Let's check what happens inside `sig` with a clean Lua+Luau recursive-descent emitter OR balanced-depth pass!
    return sig

# Let's build an exact recursive-descent Lua + Luau AST rewriter? Wait: Luraph code has NO weird syntax!
# In fact, writing a full Lua 5.1 + Luau (compound assign, //, if-expr) parser/rewriter in ~200 lines of Python guarantees 100% correctness on precedence, nested ternaries, `false`/`nil` branches, and `//`!
class Parser:
    def __init__(self, tokens):
        self.toks = [(k, v) for k, v in tokens if k not in ('WS', 'COMMENT')]
        self.n = len(self.toks)
        self.p = 0
        self.out = []
        self.expr_if_count = 0
        self.fdiv_count = 0
        self.comp_count = 0

    def peek(self, off=0):
        if self.p + off < self.n:
            return self.toks[self.p + off]
        return ('EOF', '')

    def next(self):
        t = self.peek()
        self.p += 1
        return t

    def match(self, kind, val=None):
        k, v = self.peek()
        if k == kind and (val is None or v == val):
            self.p += 1
            return (k, v)
        return None

    def expect(self, kind, val=None):
        t = self.match(kind, val)
        if not t:
            ctx = self.toks[max(0, self.p-5):min(self.n, self.p+5)]
            raise SyntaxError(f"Expected {kind} {val} at {self.p}, got {self.peek()}, ctx={ctx}")
        return t

    @staticmethod
    def join(parts):
        # Join token strings adding space only when necessary
        res = []
        prev_alnum = False
        for s in parts:
            if not s:
                continue
            c0 = s[0]
            first_alnum = c0.isalnum() or c0 == '_' or c0 == '.'
            if prev_alnum and first_alnum:
                # avoid merging identifiers/numbers/dots (like `1` + `..`? wait `1 ..` needs space if decimal!)
                res.append(' ')
            res.append(s)
            c1 = s[-1]
            prev_alnum = c1.isalnum() or c1 == '_' or c1 == '.'
        return ''.join(res)

    def parse_chunk(self, stop_kws=()):
        parts = []
        while True:
            k, v = self.peek()
            if k == 'EOF' or (k == 'KW' and v in stop_kws):
                break
            if k == 'SYM' and v == ';':
                self.next()
                parts.append(';')
                continue
            parts.append(self.parse_stmt())
            if self.match('SYM', ';'):
                parts.append(';')
        return ' '.join(parts)

    def parse_stmt(self):
        k, v = self.peek()
        if k == 'KW':
            if v == 'local':
                self.next()
                if self.match('KW', 'function'):
                    name = self.expect('ID')[1]
                    body = self.parse_funcbody()
                    return f"local function {name}{body}"
                names = [self.expect('ID')[1]]
                while self.match('SYM', ','):
                    names.append(self.expect('ID')[1])
                if self.match('SYM', '='):
                    exprs = self.parse_explist()
                    return f"local {','.join(names)}={exprs}"
                return f"local {','.join(names)}"
            elif v == 'function':
                self.next()
                fname = [self.expect('ID')[1]]
                while self.match('SYM', '.'):
                    fname.append('.' + self.expect('ID')[1])
                if self.match('SYM', ':'):
                    fname.append(':' + self.expect('ID')[1])
                body = self.parse_funcbody()
                return f"function {''.join(fname)}{body}"
            elif v == 'do':
                self.next()
                body = self.parse_chunk(('end',))
                self.expect('KW', 'end')
                return f"do {body} end"
            elif v == 'while':
                self.next()
                cond = self.parse_exp()
                self.expect('KW', 'do')
                body = self.parse_chunk(('end',))
                self.expect('KW', 'end')
                return f"while {cond} do {body} end"
            elif v == 'repeat':
                self.next()
                body = self.parse_chunk(('until',))
                self.expect('KW', 'until')
                cond = self.parse_exp()
                return f"repeat {body} until {cond}"
            elif v == 'if':
                self.next()
                cond = self.parse_exp()
                self.expect('KW', 'then')
                parts = [f"if {cond} then {self.parse_chunk(('elseif', 'else', 'end'))}"]
                while self.match('KW', 'elseif'):
                    c2 = self.parse_exp()
                    self.expect('KW', 'then')
                    parts.append(f"elseif {c2} then {self.parse_chunk(('elseif', 'else', 'end'))}")
                if self.match('KW', 'else'):
                    parts.append(f"else {self.parse_chunk(('end',))}")
                self.expect('KW', 'end')
                parts.append("end")
                return ' '.join(parts)
            elif v == 'for':
                self.next()
                first = self.expect('ID')[1]
                if self.match('SYM', '='):
                    e1 = self.parse_exp()
                    self.expect('SYM', ',')
                    e2 = self.parse_exp()
                    e3 = None
                    if self.match('SYM', ','):
                        e3 = self.parse_exp()
                    self.expect('KW', 'do')
                    body = self.parse_chunk(('end',))
                    self.expect('KW', 'end')
                    step = f",{e3}" if e3 is not None else ""
                    return f"for {first}={e1},{e2}{step} do {body} end"
                else:
                    names = [first]
                    while self.match('SYM', ','):
                        names.append(self.expect('ID')[1])
                    self.expect('KW', 'in')
                    exps = self.parse_explist()
                    self.expect('KW', 'do')
                    body = self.parse_chunk(('end',))
                    self.expect('KW', 'end')
                    return f"for {','.join(names)} in {exps} do {body} end"
            elif v == 'return':
                self.next()
                k2, v2 = self.peek()
                if k2 == 'EOF' or (k2 == 'SYM' and v2 == ';') or (k2 == 'KW' and v2 in ('end', 'else', 'elseif', 'until')):
                    return "return"
                exps = self.parse_explist()
                return f"return {exps}"
            elif v == 'break':
                self.next()
                return "break"
            elif v == '::':
                pass
        if k == 'SYM' and v == '::':
            self.next()
            lbl = self.expect('ID')[1]
            self.expect('SYM', '::')
            return f"::{lbl}::"
        # Otherwise suffixedexp: assignment, compound assignment, or functioncall
        first_exp, is_call = self.parse_suffixedexp()
        comp_map = {
            '+=': '+', '-=': '-', '*=': '*', '/=': '/', '%=': '%', '^=': '^', '..=': '..'
        }
        nk, nv = self.peek()
        if nk == 'SYM' and nv in comp_map:
            self.next()
            self.comp_count += 1
            rhs = self.parse_exp()
            op = comp_map[nv]
            return f"{first_exp}={first_exp}{op}({rhs})"
        elif nk == 'SYM' and nv == '//=':
            self.next()
            self.comp_count += 1
            rhs = self.parse_exp()
            return f"{first_exp}=math.floor(({first_exp})/({rhs}))"
        elif nk == 'SYM' and (nv == '=' or nv == ','):
            lhs = [first_exp]
            while self.match('SYM', ','):
                e, _ = self.parse_suffixedexp()
                lhs.append(e)
            self.expect('SYM', '=')
            rhs = self.parse_explist()
            return f"{','.join(lhs)}={rhs}"
        else:
            if not is_call:
                ctx = self.toks[max(0, self.p-5):min(self.n, self.p+5)]
                raise SyntaxError(f"Expected assignment or call at {self.p} after {first_exp}, got {self.peek()}, ctx={ctx}")
            return first_exp

    def parse_funcbody(self):
        self.expect('SYM', '(')
        params = []
        if not self.match('SYM', ')'):
            while True:
                if self.match('SYM', '...'):
                    params.append('...')
                    break
                params.append(self.expect('ID')[1])
                if not self.match('SYM', ','):
                    break
            self.expect('SYM', ')')
        body = self.parse_chunk(('end',))
        self.expect('KW', 'end')
        return f"({','.join(params)}) {body} end"

    def parse_explist(self):
        exps = [self.parse_exp()]
        while self.match('SYM', ','):
            exps.append(self.parse_exp())
        return ','.join(exps)

    def parse_exp(self, min_prec=0):
        # Unary operators
        k, v = self.peek()
        if (k == 'KW' and v == 'not') or (k == 'SYM' and v in ('-', '#')):
            self.next()
            op = 'not ' if v == 'not' else v
            operand = self.parse_exp(8)
            lhs = f"({op}{operand})"
        else:
            lhs = self.parse_simpleexp()

        # Lua precedence: left-assoc uses rprec = lprec + 1, right-assoc uses rprec = lprec
        bin_prec = {
            'or': (1, 2),
            'and': (2, 3),
            '<': (3, 4), '>': (3, 4), '<=': (3, 4), '>=': (3, 4), '~=': (3, 4), '==': (3, 4),
            '..': (4, 4),
            '+': (5, 6), '-': (5, 6),
            '*': (6, 7), '/': (6, 7), '//': (6, 7), '%': (6, 7),
            '^': (9, 9),
        }
        while True:
            nk, nv = self.peek()
            if (nk == 'SYM' or nk == 'KW') and nv in bin_prec:
                lprec, rprec = bin_prec[nv]
                if lprec < min_prec:
                    break
                self.next()
                rhs = self.parse_exp(rprec)
                if nv == '//':
                    self.fdiv_count += 1
                    lhs = f"math.floor(({lhs})/({rhs}))"
                elif nv in ('and', 'or'):
                    lhs = f"({lhs} {nv} {rhs})"
                elif nv == '^' or nv == '..':
                    # Preserve parens safely on unary/binary subexpressions when needed
                    lhs = f"({lhs}{nv}{rhs})"
                else:
                    lhs = f"({lhs}{nv}{rhs})"
            else:
                break
        return lhs

    def parse_simpleexp(self):
        k, v = self.peek()
        if k in ('NUM', 'STR'):
            self.next()
            return v
        elif k == 'KW' and v in ('nil', 'true', 'false'):
            self.next()
            return v
        elif k == 'SYM' and v == '...':
            self.next()
            return '...'
        elif k == 'SYM' and v == '{':
            return self.parse_tablector()
        elif k == 'KW' and v == 'function':
            self.next()
            return 'function' + self.parse_funcbody()
        elif k == 'KW' and v == 'if':
            return self.parse_ifexp()
        else:
            e, _ = self.parse_suffixedexp()
            return e

    def parse_ifexp(self):
        self.expr_if_count += 1
        self.expect('KW', 'if')
        branches = []
        c = self.parse_exp()
        self.expect('KW', 'then')
        t = self.parse_exp()
        branches.append((c, t))
        while self.match('KW', 'elseif'):
            c2 = self.parse_exp()
            self.expect('KW', 'then')
            t2 = self.parse_exp()
            branches.append((c2, t2))
        self.expect('KW', 'else')
        el = self.parse_exp()
        # Use ({ [false]=..., [true]=... })? No! That evaluates both!
        # Use ((C) and {T} or {E})[1] — lazy evaluation, works for false/nil, works with varargs `...`!
        # Build right-to-left:
        cur = el
        for cond, then_e in reversed(branches):
            cur = f"(({cond})and{{{then_e}}}or{{{cur}}})[1]"
        return cur

    def parse_suffixedexp(self):
        e, is_call = self.parse_primaryexp(), False
        while True:
            k, v = self.peek()
            if k == 'SYM' and v == '.':
                self.next()
                fld = self.expect('ID')[1]
                e = f"{e}.{fld}"
                is_call = False
            elif k == 'SYM' and v == '[':
                self.next()
                idx = self.parse_exp()
                self.expect('SYM', ']')
                e = f"{e}[{idx}]"
                is_call = False
            elif k == 'SYM' and v == ':':
                self.next()
                meth = self.expect('ID')[1]
                args = self.parse_funcargs()
                e = f"{e}:{meth}{args}"
                is_call = True
            elif (k == 'SYM' and v in ('(', '{')) or k == 'STR':
                args = self.parse_funcargs()
                e = f"{e}{args}"
                is_call = True
            else:
                break
        return e, is_call

    def parse_primaryexp(self):
        k, v = self.peek()
        if k == 'SYM' and v == '(':
            self.next()
            e = self.parse_exp()
            self.expect('SYM', ')')
            return f"({e})"
        elif k == 'ID':
            self.next()
            return v
        else:
            ctx = self.toks[max(0, self.p-5):min(self.n, self.p+5)]
            raise SyntaxError(f"Unexpected token in primaryexp at {self.p}: {self.peek()}, ctx={ctx}")

    def parse_funcargs(self):
        k, v = self.peek()
        if k == 'SYM' and v == '(':
            self.next()
            if self.match('SYM', ')'):
                return "()"
            exps = self.parse_explist()
            self.expect('SYM', ')')
            return f"({exps})"
        elif k == 'SYM' and v == '{':
            return self.parse_tablector()
        elif k == 'STR':
            self.next()
            return v
        else:
            raise SyntaxError(f"Expected funcargs at {self.p}, got {self.peek()}")

    def parse_tablector(self):
        self.expect('SYM', '{')
        fields = []
        while not self.match('SYM', '}'):
            k, v = self.peek()
            if k == 'SYM' and v == '[':
                self.next()
                ke = self.parse_exp()
                self.expect('SYM', ']')
                self.expect('SYM', '=')
                ve = self.parse_exp()
                fields.append(f"[{ke}]={ve}")
            elif k == 'ID' and self.peek(1) == ('SYM', '='):
                name = self.next()[1]
                self.next()
                ve = self.parse_exp()
                fields.append(f"{name}={ve}")
            else:
                fields.append(self.parse_exp())
            if not (self.match('SYM', ',') or self.match('SYM', ';')):
                self.expect('SYM', '}')
                break
        return '{' + ','.join(fields) + '}'

if __name__ == '__main__':
    in_path = sys.argv[1]
    out_path = sys.argv[2]
    with open(in_path, 'r', encoding='utf-8', errors='replace') as f:
        src = f.read()
    # Skip Luau type annotations? Luraph v15.1 doesn't emit Luau type annotations (only //, compound assigns, if-then-else expr)
    tokens = tokenize(src)
    parser = Parser(tokens)
    out = parser.parse_chunk()
    assert parser.p == parser.n, f"Unconsumed tokens at {parser.p}/{parser.n}: {parser.toks[parser.p:parser.p+5]}"
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(out)
    print(f"Transpiled {in_path} -> {out_path}: expr_if={parser.expr_if_count}, fdiv={parser.fdiv_count}, comp={parser.comp_count}")
