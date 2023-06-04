import 'instruction.dart';
import 'byte_code_builder.dart';
import 'module.dart';

abstract class AstNode {
  bool isBoolean() => false;

  bool isConstant();
  int constantValue();
  void addInstructions(ScriptByteCodeBuilder builder);

  AstNode simplify() {
    if (isConstant()) {
      return IntValueAstNode(constantValue());
    }
    return this;
  }
}

class StringValueAstNode extends AstNode {
  StringValueAstNode(this.value);

  // Do NOT mark this as constant, otherwise integer folding instructions
  // will be attempted.
  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    builder.strings.add(value);
    builder.addInstruction(PushStringValueScriptInstruction(value));
  }

  final String value;
}

class ByteIndexAstNode extends AstNode {
  ByteIndexAstNode(this.byteValue, this.index);

  // Do NOT mark this as constant, otherwise integer folding instructions
  // will be attempted.
  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    byteValue.addInstructions(builder);
    index.addInstructions(builder);

    builder.addInstruction(
        OpcodeScriptInstruction(ScriptOperatorOpcode.byteLookup));
  }

  final AstNode byteValue;
  final AstNode index;
}

class IntValueAstNode extends AstNode {
  IntValueAstNode(this.value);

  @override
  bool isConstant() => true;

  @override
  int constantValue() => value;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    builder.addInstruction(PushIntValueScriptInstruction(value));
  }

  @override
  AstNode simplify() {
    return this;
  }

  final int value;
}

abstract class UnaryOperatorAstNode extends AstNode {
  UnaryOperatorAstNode(this.statement);

  @override
  bool isConstant() => statement.isConstant();

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    if (isConstant()) {
      builder.addInstruction(PushIntValueScriptInstruction(constantValue()));
      return;
    }
    statement.addInstructions(builder);
    builder.addInstruction(OpcodeScriptInstruction(opcode));
  }

  ScriptOperatorOpcode get opcode;

  final AstNode statement;
}

class NotAstNode extends UnaryOperatorAstNode {
  NotAstNode(super.statement);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() => statement.constantValue() == 0 ? 1 : 0;

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.not;
}

class NegateAstNode extends UnaryOperatorAstNode {
  NegateAstNode(super.statement);

  @override
  int constantValue() => -statement.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.negative;
}

class BitwiseNotAstNode extends AstNode {
  BitwiseNotAstNode(this.expression);

  @override
  bool isConstant() => expression.isConstant();

  @override
  int constantValue() => ~expression.constantValue();

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    if (isConstant()) {
      builder.addInstruction(PushIntValueScriptInstruction(constantValue()));
      return;
    }
    expression.addInstructions(builder);
    builder
        .addInstruction(OpcodeScriptInstruction(ScriptOperatorOpcode.negative));
    builder.addInstruction(
        OpcodeScriptInstruction(ScriptOperatorOpcode.decrement));
  }

  final AstNode expression;
}

abstract class BinaryOperatorAstNode extends AstNode {
  BinaryOperatorAstNode(this.statementA, this.statementB);

  @override
  bool isConstant() => statementA.isConstant() && statementB.isConstant();

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    statementA.addInstructions(builder);
    statementB.addInstructions(builder);
    builder.addInstruction(OpcodeScriptInstruction(opcode));
  }

  ScriptOperatorOpcode get opcode;

  final AstNode statementA;
  final AstNode statementB;
}

enum TermMode {
  add,
  subtract,
}

class Term {
  const Term(this.mode, this.statement);

  final TermMode mode;
  final AstNode statement;
}

class TermsAstNode extends AstNode {
  @override
  bool isConstant() => terms.every((e) => e.statement.isConstant());

  @override
  int constantValue() {
    var result = 0;
    for (final term in terms) {
      int value = term.statement.constantValue();
      switch (term.mode) {
        case TermMode.add:
          result += value;
          break;
        case TermMode.subtract:
          result -= value;
          break;
      }
    }
    return result;
  }

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    if (terms.length == 2) {
      // Detect 1 + x
      if (terms[0].mode == TermMode.add &&
          terms[0].statement.isConstant() &&
          terms[1].mode == TermMode.add &&
          terms[0].statement.constantValue() == 1) {
        terms[1].statement.addInstructions(builder);
        builder.addInstruction(
            OpcodeScriptInstruction(ScriptOperatorOpcode.increment));
        return;
      }

      // Detect x + 1 and x - 1
      if (terms[0].mode == TermMode.add &&
          terms[1].mode == TermMode.add &&
          terms[1].statement.constantValue() == 1) {
        terms[0].statement.addInstructions(builder);
        switch (terms[1].mode) {
          case TermMode.add:
            builder.addInstruction(
                OpcodeScriptInstruction(ScriptOperatorOpcode.increment));
            break;
          case TermMode.subtract:
            builder.addInstruction(
                OpcodeScriptInstruction(ScriptOperatorOpcode.decrement));
            break;
        }
        return;
      }
    }

    bool isFirst = true;
    for (final term in terms) {
      term.statement.addInstructions(builder);
      if (isFirst) {
        isFirst = false;
      } else {
        switch (term.mode) {
          case TermMode.add:
            builder.addInstruction(
                OpcodeScriptInstruction(ScriptOperatorOpcode.add));
            break;
          case TermMode.subtract:
            builder.addInstruction(
                OpcodeScriptInstruction(ScriptOperatorOpcode.subtract));
            break;
        }
      }
    }
  }

  final terms = <Term>[];
}

class MultiplyAstNode extends BinaryOperatorAstNode {
  MultiplyAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() * statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.multiply;
}

class QuotientAstNode extends BinaryOperatorAstNode {
  QuotientAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() ~/ statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.quotient;
}

class RemainderAstNode extends BinaryOperatorAstNode {
  RemainderAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue().remainder(statementB.constantValue());

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.remainder;
}

class BitwiseAndAstNode extends BinaryOperatorAstNode {
  BitwiseAndAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() & statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.bitwiseAnd;
}

class BitwiseOrAstNode extends BinaryOperatorAstNode {
  BitwiseOrAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() | statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.bitwiseOr;
}

class BitwiseXorAstNode extends BinaryOperatorAstNode {
  BitwiseXorAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() ^ statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.bitwiseXor;
}

class BitShiftLeftAstNode extends BinaryOperatorAstNode {
  BitShiftLeftAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() << statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.shiftLeft;
}

class ArithmeticBitShiftRightAstNode extends BinaryOperatorAstNode {
  ArithmeticBitShiftRightAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() >> statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.arithmeticShiftRight;
}

class LogicalBitShiftRightAstNode extends BinaryOperatorAstNode {
  LogicalBitShiftRightAstNode(super.statementA, super.statementB);

  @override
  int constantValue() =>
      statementA.constantValue() >>> statementB.constantValue();

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.logicalShiftRight;
}

class LogicalAndAstNode extends BinaryOperatorAstNode {
  LogicalAndAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() != 0 && statementB.constantValue() != 0) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.logicalAnd;
}

class LogicalOrAstNode extends BinaryOperatorAstNode {
  LogicalOrAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() != 0 || statementB.constantValue() != 0) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.logicalOr;
}

class EqualsAstNode extends BinaryOperatorAstNode {
  EqualsAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() == statementB.constantValue()) {
      return 1;
    }
    return 0;
  }

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    if (statementA.isConstant() && statementA.constantValue() == 0) {
      statementB.addInstructions(builder);
      builder.addInstruction(OpcodeScriptInstruction(ScriptOperatorOpcode.not));
    } else if (statementB.isConstant() && statementB.constantValue() == 0) {
      statementA.addInstructions(builder);
      builder.addInstruction(OpcodeScriptInstruction(ScriptOperatorOpcode.not));
    } else {
      super.addInstructions(builder);
    }
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.equals;
}

class NotEqualsAstNode extends BinaryOperatorAstNode {
  NotEqualsAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() != statementB.constantValue()) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.notEquals;
}

class LessThanAstNode extends BinaryOperatorAstNode {
  LessThanAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() < statementB.constantValue()) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.lessThan;
}

class LessThanOrEqualToAstNode extends BinaryOperatorAstNode {
  LessThanOrEqualToAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() <= statementB.constantValue()) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.lessThanOrEqualTo;
}

class GreaterThanAstNode extends BinaryOperatorAstNode {
  GreaterThanAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() > statementB.constantValue()) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.greaterThan;
}

class GreaterThanOrEqualToAstNode extends BinaryOperatorAstNode {
  GreaterThanOrEqualToAstNode(super.statementA, super.statementB);

  @override
  bool isBoolean() => true;

  @override
  int constantValue() {
    if (statementA.constantValue() >= statementB.constantValue()) {
      return 1;
    }
    return 0;
  }

  @override
  ScriptOperatorOpcode get opcode => ScriptOperatorOpcode.greaterThanOrEqualTo;
}

class NopAstNode extends AstNode {
  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {}
}

class ForStatementAstNode extends AstNode {
  ForStatementAstNode({
    this.initialization,
    required this.condition,
    this.update,
    required this.body,
  });

  final AstNode? initialization;
  final AstNode condition;
  final AstNode? update;
  final AstNode body;

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    // Layout is:
    //   initialization:
    //  condition:
    //   condition -> end
    //   body
    //   update
    //   jmp condition
    //  end:

    initialization?.addInstructions(builder);
    final jumpToConditionInstruction = JumpScriptInstruction();
    builder.addInstruction(jumpToConditionInstruction.target);
    condition.addInstructions(builder);

    final lastInstruction = builder.instructions.last;
    late final JumpScriptInstructionBase jumpToEndInstruction;
    if (lastInstruction is OpcodeScriptInstruction &&
        lastInstruction.opcode == ScriptOperatorOpcode.not) {
      builder.instructions.removeLast();
      jumpToEndInstruction = JumpIfNotZeroScriptInstruction();
    } else {
      jumpToEndInstruction = JumpIfZeroScriptInstruction();
    }
    builder.addInstruction(jumpToEndInstruction);
    body.addInstructions(builder);
    update?.addInstructions(builder);
    builder.addInstruction(jumpToConditionInstruction);
    builder.addInstruction(jumpToEndInstruction.target);
  }
}

class IfStatementAstNode extends AstNode {
  IfStatementAstNode({
    required this.condition,
    required this.whenTrue,
    this.whenFalse,
  });

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    if (condition.isConstant()) {
      if (condition.constantValue() != 0) {
        whenTrue.addInstructions(builder);
      } else {
        whenFalse?.addInstructions(builder);
      }
    } else {
      condition.addInstructions(builder);

      final lastInstruction = builder.instructions.last;
      late final JumpScriptInstructionBase jumpInstruction;
      if (lastInstruction is OpcodeScriptInstruction &&
          lastInstruction.opcode == ScriptOperatorOpcode.not) {
        builder.instructions.removeLast();
        jumpInstruction = JumpIfNotZeroScriptInstruction();
      } else {
        jumpInstruction = JumpIfZeroScriptInstruction();
      }
      final elseNop = jumpInstruction.target;
      builder.addInstruction(jumpInstruction);

      whenTrue.addInstructions(builder);
      NopScriptInstruction? endNop;
      if (whenFalse != null) {
        final jumpInstruction = JumpScriptInstruction();
        endNop = jumpInstruction.target;
        builder.addInstruction(jumpInstruction);
      }
      builder.addInstruction(elseNop);
      whenFalse?.addInstructions(builder);
      if (endNop != null) {
        builder.addInstruction(endNop);
      }
    }
  }

  final AstNode condition;
  final AstNode whenTrue;
  final AstNode? whenFalse;
}

class StatementListAstNode extends AstNode {
  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    for (final statement in statements) {
      statement.addInstructions(builder);
    }
  }

  final statements = <AstNode>[];

  void add(AstNode statement) => statements.add(statement);
}

class LoadGlobalValueArrayAstNode extends AstNode {
  LoadGlobalValueArrayAstNode({required this.name, required this.index});

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    throw Exception("Global value array $name must be indexed");
  }

  final String name;
  final int index;
}

class LoadIndexedGlobalValueAstNode extends AstNode {
  LoadIndexedGlobalValueAstNode(this.globalValue, this.indexExpression);

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    indexExpression.addInstructions(builder);
    builder
        .addInstruction(LoadIndexedGlobalValueInstruction(globalValue.index));
  }

  final LoadGlobalValueArrayAstNode globalValue;
  final AstNode indexExpression;
}

class LoadValueAstNode extends AstNode {
  LoadValueAstNode({
    required this.isGlobal,
    required this.index,
  });

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    if (isGlobal) {
      builder.addInstruction(LoadGlobalValueInstruction(index));
    } else {
      builder.addInstruction(LoadLocalValueInstruction(index));
    }
  }

  final bool isGlobal;
  final int index;
}

class CallFunctionAstNode extends AstNode {
  CallFunctionAstNode({
    required this.usesValue,
    required this.name,
    required this.parameters,
  });

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    final definition = builder.module.functions[name];
    if (definition == null) {
      throw FormatException('No such function $name');
    }
    if (definition.numberOfParameters != parameters.length) {
      throw FormatException(
        '$name expects ${definition.numberOfParameters} parameters '
        'but ${parameters.length} provided',
      );
    }
    if (usesValue && !definition.hasReturnValue) {
      throw FormatException('$name does not return a value');
    }

    for (final parameter in parameters) {
      parameter.addInstructions(builder);
    }

    if (definition is InBuiltScriptFunction) {
      builder.addInstruction(
        CallInBuiltFunctionInstruction(definition),
      );
    } else {
      builder.addInstruction(CallFunctionInstruction(name));
    }

    if (!usesValue && definition.hasReturnValue) {
      builder.addInstruction(PopValueInstruction());
    }
  }

  final bool usesValue;
  final String name;
  final List<AstNode> parameters;
}

class PushFunctionAddress extends AstNode {
  PushFunctionAddress({required this.name});

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    final definition = builder.module.functions[name];
    if (definition == null) {
      throw FormatException('No such function $name');
    }
    builder.addInstruction(PushFunctionAddressInstruction(name));
  }

  final String name;
}

class StoreValueAstNode extends AstNode {
  StoreValueAstNode({
    required this.isGlobal,
    required this.index,
    required this.expression,
  });

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    expression.addInstructions(builder);
    if (isGlobal) {
      builder.addInstruction(StoreGlobalValueInstruction(index));
    } else {
      builder.addInstruction(StoreLocalValueInstruction(index));
    }
  }

  final bool isGlobal;
  final int index;
  final AstNode expression;
}

class StoreIndexedGlobalValueAstNode extends AstNode {
  StoreIndexedGlobalValueAstNode({
    required this.globalValueIndex,
    required this.indexExpression,
    required this.expression,
  });

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    indexExpression.addInstructions(builder);
    expression.addInstructions(builder);
    builder
        .addInstruction(StoreIndexedGlobalValueInstruction(globalValueIndex));
  }

  final int globalValueIndex;
  final AstNode indexExpression;
  final AstNode expression;
}

class ReturnAstNode extends AstNode {
  ReturnAstNode(this.expression);

  @override
  bool isConstant() => false;

  @override
  int constantValue() => 0;

  @override
  void addInstructions(ScriptByteCodeBuilder builder) {
    expression?.addInstructions(builder);
    builder.addInstruction(ReturnScriptInstruction());
  }

  AstNode? expression;
}
