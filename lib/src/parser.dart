import 'ast.dart';
import 'module.dart';
import 'token.dart';
import 'tokenizer.dart';

class Parser {
  static const maximumGlobalVariableCount = 64;

  factory Parser({required String input, required String filename}) {
    return Parser.tokenizer(Tokenizer(input, filename));
  }

  Parser.tokenizer(Tokenizer tokenizer)
      : _tokens = tokenizer.tokenize().iterator {
    _nextToken();
  }

  final Iterator<Token> _tokens;

  late ScriptModule _module;
  late Token _currentToken;

  ScriptFunction? _function;

  void _nextToken() {
    if (_tokens.moveNext()) {
      _currentToken = _tokens.current;
    } else {
      _currentToken = const Token(type: TokenType.eof, line: 0, column: 0);
    }
  }

  bool _hasTokenAndAdvance(TokenType type) {
    if (_currentToken.type != type) return false;
    _nextToken();
    return true;
  }

  void _assertToken(TokenType type) {
    if (!_hasTokenAndAdvance(type)) {
      throw FormatException('Expected $type, found $_currentToken');
    }
  }

  bool _isScopeEnd(TokenType endToken) {
    if (_currentToken.type != endToken) {
      if (_currentToken.type == TokenType.eof) {
        _assertToken(endToken);
      }
      return false;
    }
    _nextToken();
    return true;
  }

  ScriptModule parse() {
    _module = ScriptModule();
    for (final builtInFunction in InBuiltScriptFunction.values) {
      _module.functions[builtInFunction.name] = builtInFunction;
    }
    parseModule();

    // Patch or create init function with global variable inits.
    var initFunction = _module.functions['init'] as ScriptFunction?;
    if (initFunction == null) {
      initFunction = ScriptFunction('init');
      initFunction.statements = StatementListAstNode();
      _module.functions['init'] = initFunction;
    } else {
      if (initFunction.hasReturnValue) {
        throw const FormatException('init function should not return a value');
      }
      if (initFunction.numberOfParameters > 0) {
        throw const FormatException(
          'init function should not take any parameters',
        );
      }
    }

    final globalInitializers = <AstNode>[];
    for (final global in _module.globals.values) {
      final initializer = global.initializer;
      if (initializer == null) continue;
      globalInitializers.add(
        StoreValueAstNode(
          isGlobal: true,
          index: global.index,
          expression: initializer,
        ),
      );
    }
    initFunction.statements.statements.insertAll(0, globalInitializers);

    // Create tick function if it doesn't exist.
    var tickFunction = _module.functions['tick'] as ScriptFunction?;
    if (tickFunction == null) {
      tickFunction = ScriptFunction('tick');
      tickFunction.statements = StatementListAstNode();
      _module.functions['tick'] = tickFunction;
    }

    return _module;
  }

  void parseModule() {
    while (_currentToken.type != TokenType.eof) {
      switch (_currentToken.type) {
        case TokenType.constKeyword:
          _parseConst();
          break;

        case TokenType.varKeyword:
          _parseGlobalVar();
          break;

        case TokenType.funcKeyword:
          _parseFunc();
          break;

        default:
          throw FormatException(
            'Unexpected token $_currentToken. '
            'Expected \'const\', \'var\' or \'func\' declaration.',
          );
      }
    }
  }

  void _assertUniqueName(String name) {
    if (_module.constants.containsKey(name)) {
      throw Exception('$name already defined as a cosntant');
    }
    if (_module.globals.containsKey(name)) {
      throw Exception('$name already defined as a global');
    }
    if (_module.functions.containsKey(name)) {
      throw Exception('$name already defined as a function');
    }
    if (_function?.parameters.containsKey(name) ?? false) {
      throw Exception('$name already defined as a parameter');
    }
    if (_function?.locals.containsKey(name) ?? false) {
      throw Exception('$name already defined as a local');
    }
  }

  void _parseConst() {
    _assertToken(TokenType.constKeyword);
    final nameToken = _currentToken;
    _assertToken(TokenType.identifier);
    final name = nameToken.stringValue!;
    _assertToken(TokenType.assign);
    final expression = _parseExpression();
    _assertToken(TokenType.semiColon);

    _assertUniqueName(name);

    if (!expression.isConstant() && expression is! StringValueAstNode) {
      throw Exception('$name not a constant value');
    }

    _module.constants[nameToken.stringValue!] = expression;
  }

  void _parseGlobalVar() {
    _assertToken(TokenType.varKeyword);
    final nameToken = _currentToken;
    _assertToken(TokenType.identifier);
    final name = nameToken.stringValue!;
    AstNode? initializer;
    if (_currentToken.type == TokenType.assign) {
      _assertToken(TokenType.assign);
      initializer = _parseExpression();
    }
    _assertToken(TokenType.semiColon);

    _assertUniqueName(name);

    final index = _module.globals.length;

    if (index >= maximumGlobalVariableCount) {
      throw FormatException('Too many global varialbes near $_currentToken');
    }

    _module.globals[name] = ScriptGlobal(
      name: name,
      index: index,
      initializer: initializer,
    );
  }

  void _parseFunc() {
    _assertToken(TokenType.funcKeyword);
    final nameToken = _currentToken;
    _assertToken(TokenType.identifier);
    final name = nameToken.stringValue!;
    _assertToken(TokenType.openParen);

    _assertUniqueName(name);

    final function = ScriptFunction(name);
    _module.functions[name] = function;

    final previousFunction = _function;
    _function = function;

    while (!_isScopeEnd(TokenType.closeParen)) {
      final parameterName = _currentToken;
      _assertToken(TokenType.identifier);
      function.addParameter(parameterName.stringValue!);

      if (_currentToken.type == TokenType.comma) {
        _nextToken();
      } else if (_currentToken.type != TokenType.closeParen) {
        throw FormatException(
          'Unexpected end of parameter list for $nameToken near $_currentToken',
        );
      }
    }

    if (_currentToken.type == TokenType.varKeyword) {
      _nextToken();
      function.hasReturnValue = true;
    }

    function.statements = _parseBlock();

    _function = previousFunction;
  }

  AstNode _parsePrimary() {
    // Brackets, constant or function call.
    switch (_currentToken.type) {
      case TokenType.intValue:
        final value = _currentToken.intValue!;
        _nextToken();
        return IntValueAstNode(value);

      case TokenType.stringValue:
        final value = _currentToken.stringValue!;
        _nextToken();
        return StringValueAstNode(value);

      case TokenType.openParen:
        _nextToken();
        final expression = _parseExpression();
        _assertToken(TokenType.closeParen);
        return expression;

      case TokenType.identifier:
        // Global, local, constant or function call
        final name = _currentToken.stringValue!;
        _nextToken();

        if (_currentToken.type == TokenType.openParen) {
          // Function call.
          final parameters = _parseParameterList();
          return CallFunctionAstNode(
            usesValue: true,
            name: name,
            parameters: parameters,
          );
        } else {
          // Check parameters
          if (_function?.parameters.containsKey(name) ?? false) {
            return LoadParamAstNode(index: _function!.parameters[name]!);
          }

          // Check locals
          if (_function?.locals.containsKey(name) ?? false) {
            return LoadValueAstNode(
              isGlobal: false,
              index: _function!.locals[name]!,
            );
          }

          // Check globals
          if (_module.globals.containsKey(name)) {
            return LoadValueAstNode(
              isGlobal: true,
              index: _module.globals[name]!.index,
            );
          }

          // Check constants
          final constantValue = _module.constants[name];
          if (constantValue != null) {
            return constantValue;
          }

          throw FormatException('Unknown identifier $name');
        }

      default:
        throw FormatException(
          'Unexpected primary expression $_currentToken',
        );
    }
  }

  AstNode _parseUnary() {
    switch (_currentToken.type) {
      case TokenType.minus:
        _nextToken();
        return NegateAstNode(_parsePrimary());

      case TokenType.not:
        _nextToken();
        return NotAstNode(_parsePrimary());

      case TokenType.plus:
        _nextToken();
        return _parsePrimary();

      default:
        return _parsePrimary();
    }
  }

  AstNode _parseFactor() {
    const factorTokenTypes = {
      TokenType.multiply,
      TokenType.quotient,
      TokenType.remainder,
    };

    var result = _parseUnary();
    while (factorTokenTypes.contains(_currentToken.type)) {
      final type = _currentToken.type;
      _nextToken();
      switch (type) {
        case TokenType.multiply:
          result = MultiplyAstNode(result, _parseUnary()).simplify();
          break;
        case TokenType.quotient:
          result = QuotientAstNode(result, _parseUnary()).simplify();
          break;
        case TokenType.remainder:
          result = RemainderAstNode(result, _parseUnary()).simplify();
          break;
        default:
          throw Exception('Internal error');
      }
    }
    return result;
  }

  AstNode _parseTerm() {
    const termTokenTypes = {TokenType.plus, TokenType.minus};

    final factor = _parseFactor();
    if (!termTokenTypes.contains(_currentToken.type)) {
      return factor;
    }

    final termsExpression = TermsAstNode();
    termsExpression.terms.add(Term(TermMode.add, factor));

    while (termTokenTypes.contains(_currentToken.type)) {
      final type = _currentToken.type;
      _nextToken();
      switch (type) {
        case TokenType.plus:
          termsExpression.terms.add(Term(TermMode.add, _parseFactor()));
          break;
        case TokenType.minus:
          termsExpression.terms.add(Term(TermMode.subtract, _parseFactor()));
          break;
        default:
          throw Exception('Internal error');
      }
    }

    return termsExpression.simplify();
  }

  AstNode _parseBitShift() {
    const bitShiftTokenTypes = {
      TokenType.shiftLeft,
      TokenType.arithmeticShiftRight,
      TokenType.logicalShiftRight,
    };

    var result = _parseTerm();
    while (bitShiftTokenTypes.contains(_currentToken.type)) {
      final type = _currentToken.type;
      _nextToken();
      switch (type) {
        case TokenType.shiftLeft:
          result = BitShiftLeftAstNode(result, _parseTerm()).simplify();
          break;
        case TokenType.arithmeticShiftRight:
          result =
              ArithmeticBitShiftRightAstNode(result, _parseTerm()).simplify();
          break;
        case TokenType.logicalShiftRight:
          result = LogicalBitShiftRightAstNode(result, _parseTerm()).simplify();
          break;
        default:
          throw Exception('Internal error');
      }
    }
    return result;
  }

  AstNode _parseComparison() {
    const comparisonTokenTypes = {
      TokenType.equals,
      TokenType.notEquals,
      TokenType.lessThan,
      TokenType.lessThanOrEqualTo,
      TokenType.greaterThan,
      TokenType.greaterThanOrEqualTo,
    };

    final result = _parseBitShift();

    if (!comparisonTokenTypes.contains(_currentToken.type)) {
      return result;
    }

    final type = _currentToken.type;
    _nextToken();
    switch (type) {
      case TokenType.equals:
        return EqualsAstNode(result, _parseBitShift()).simplify();
      case TokenType.notEquals:
        return NotEqualsAstNode(result, _parseBitShift()).simplify();
      case TokenType.lessThan:
        return LessThanAstNode(result, _parseBitShift()).simplify();
      case TokenType.lessThanOrEqualTo:
        return LessThanOrEqualToAstNode(result, _parseBitShift()).simplify();
      case TokenType.greaterThan:
        return GreaterThanAstNode(result, _parseBitShift()).simplify();
      case TokenType.greaterThanOrEqualTo:
        return GreaterThanOrEqualToAstNode(result, _parseBitShift()).simplify();
      default:
        throw Exception('Internal error');
    }
  }

  AstNode _parseBitwise() {
    const bitwiseTokenTypes = {
      TokenType.bitwiseAnd,
      TokenType.bitwiseOr,
      TokenType.bitwiseXor,
    };

    var result = _parseComparison();
    while (bitwiseTokenTypes.contains(_currentToken.type)) {
      final type = _currentToken.type;
      _nextToken();
      switch (type) {
        case TokenType.bitwiseAnd:
          result = BitwiseAndAstNode(result, _parseComparison()).simplify();
          break;
        case TokenType.bitwiseOr:
          result = BitwiseOrAstNode(result, _parseComparison()).simplify();
          break;
        case TokenType.bitwiseXor:
          result = BitwiseXorAstNode(result, _parseComparison()).simplify();
          break;
        default:
          throw Exception('Internal error');
      }
    }
    return result;
  }

  AstNode _parseLogicalAnd() {
    var result = _parseBitwise();
    while (_currentToken.type == TokenType.and) {
      _nextToken();
      result = LogicalAndAstNode(result, _parseBitwise()).simplify();
    }
    return result;
  }

  AstNode _parseLogicalOr() {
    var result = _parseLogicalAnd();
    while (_currentToken.type == TokenType.or) {
      _nextToken();
      result = LogicalOrAstNode(result, _parseLogicalAnd()).simplify();
    }
    return result;
  }

  AstNode _parseExpression() => _parseLogicalOr();

  AstNode _parseIfStatement() {
    _assertToken(TokenType.ifKeyword);
    _assertToken(TokenType.openParen);
    final condition = _parseExpression();
    _assertToken(TokenType.closeParen);
    final whenTrue = _parseStatement();

    if (_currentToken.type != TokenType.elseKeyword) {
      return IfStatementAstNode(condition: condition, whenTrue: whenTrue);
    }
    _nextToken();
    if (_currentToken.type == TokenType.ifKeyword) {
      return IfStatementAstNode(
        condition: condition,
        whenTrue: whenTrue,
        whenFalse: _parseIfStatement(),
      );
    }
    return IfStatementAstNode(
      condition: condition,
      whenTrue: whenTrue,
      whenFalse: _parseStatement(),
    );
  }

  AstNode _parseLocalVar() {
    _assertToken(TokenType.varKeyword);
    final nameToken = _currentToken;
    _assertToken(TokenType.identifier);
    final name = nameToken.stringValue!;
    AstNode? initializer;
    if (_currentToken.type == TokenType.assign) {
      _assertToken(TokenType.assign);
      initializer = _parseExpression();
    }
    _assertToken(TokenType.semiColon);

    _assertUniqueName(name);

    final index = _function!.addLocalVar(name);
    if (initializer == null) {
      return NopAstNode();
    }

    return StoreValueAstNode(
      isGlobal: false,
      index: index,
      expression: initializer,
    );
  }

  AstNode _parseAssignment(String name, {bool requireSemicolon = true}) {
    _assertToken(TokenType.assign);
    final value = _parseExpression();
    if (requireSemicolon) {
      _assertToken(TokenType.semiColon);
    }

    // Assignment can be to global or local.
    // Find out index.
    bool isGlobal;
    int index = 0;

    if (_module.globals.containsKey(name)) {
      isGlobal = true;
      index = _module.globals[name]!.index;
    } else if (_function!.locals.containsKey(name)) {
      isGlobal = false;
      index = _function!.locals[name]!;
    } else {
      throw FormatException('Unknown variable $name');
    }

    return StoreValueAstNode(
      isGlobal: isGlobal,
      index: index,
      expression: value,
    );
  }

  List<AstNode> _parseParameterList() {
    _assertToken(TokenType.openParen);
    final result = <AstNode>[];
    while (!_isScopeEnd(TokenType.closeParen)) {
      result.add(_parseExpression());

      if (_currentToken.type == TokenType.comma) {
        _nextToken();
      } else if (_currentToken.type != TokenType.closeParen) {
        throw FormatException(
          'Unexpected end of parameter list near $_currentToken',
        );
      }
    }
    return result;
  }

  AstNode _parseAssignOrFunctionCall({bool requireSemicolon = true}) {
    final nameToken = _currentToken;
    _assertToken(TokenType.identifier);
    final name = nameToken.stringValue!;

    switch (_currentToken.type) {
      case TokenType.assign:
        return _parseAssignment(name, requireSemicolon: requireSemicolon);

      case TokenType.openParen:
        final parameters = _parseParameterList();
        _assertToken(TokenType.semiColon);
        return CallFunctionAstNode(
          usesValue: false,
          name: name,
          parameters: parameters,
        );

      default:
        throw FormatException(
          'Expected assignment or function call, found $_currentToken',
        );
    }
  }

  AstNode _parseReturn() {
    _assertToken(TokenType.returnKeyword);

    AstNode? expression;
    if (_function!.hasReturnValue) {
      expression = _parseExpression();
    }

    _assertToken(TokenType.semiColon);
    return ReturnAstNode(expression);
  }

  AstNode _parseForStatement() {
    // Start a new scope.
    _assertToken(TokenType.forKeyword);
    _assertToken(TokenType.openParen);

    _function?.beginLocalScope();
    AstNode? initialization;

    switch (_currentToken.type) {
      case TokenType.varKeyword:
        initialization = _parseLocalVar();
        break;
      case TokenType.identifier:
        initialization = _parseAssignOrFunctionCall();
        break;
      case TokenType.semiColon:
        _assertToken(TokenType.semiColon);
        break;
      default:
        throw FormatException(
          'Expected if-initialization statement, found $_currentToken',
        );
    }

    final condition = _parseExpression();
    _assertToken(TokenType.semiColon);

    AstNode? update;
    switch (_currentToken.type) {
      case TokenType.identifier:
        update = _parseAssignOrFunctionCall(requireSemicolon: false);
        break;
      case TokenType.closeParen:
        break;
      default:
        throw FormatException(
          'Expected if-update statement, found $_currentToken',
        );
    }

    _assertToken(TokenType.closeParen);

    final body = _parseBlock();

    _function?.endLocalScope();

    return ForStatementAstNode(
      initialization: initialization,
      condition: condition,
      update: update,
      body: body,
    );
  }

  AstNode _parseStatement() {
    switch (_currentToken.type) {
      case TokenType.openBrace:
        return _parseBlock();
      case TokenType.ifKeyword:
        return _parseIfStatement();
      case TokenType.varKeyword:
        return _parseLocalVar();
      case TokenType.identifier:
        return _parseAssignOrFunctionCall();
      case TokenType.returnKeyword:
        return _parseReturn();
      case TokenType.forKeyword:
        return _parseForStatement();
      default:
        throw FormatException('Expected statement, found $_currentToken');
    }
  }

  StatementListAstNode _parseBlock() {
    // Start a new scope.
    _assertToken(TokenType.openBrace);
    final statements = StatementListAstNode();
    _function?.beginLocalScope();
    while (!_isScopeEnd(TokenType.closeBrace)) {
      statements.add(_parseStatement());
    }
    _function?.endLocalScope();
    return statements;
  }
}
