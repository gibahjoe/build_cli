// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: implementation_imports

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart'
    show InheritanceManager3; // ignore: deprecated_member_use
import 'package:meta/meta.dart';
import 'package:source_gen/source_gen.dart';

@alwaysThrows
T throwBugFound<T>(FieldElement element) =>
    throwUnsupported(element, "You've hit a bug in build_cli!",
        todo: 'Please rerun your build with --verbose and file as issue '
            'with the stace trace.');

@alwaysThrows
T throwUnsupported<T>(FieldElement element, String message, {String todo}) =>
    throw InvalidGenerationSourceError(
        'Could not handle field `${element.displayName}`. $message',
        element: element,
        todo: todo);

/// If [type] is the [Type] or implements the [Type] represented by [checker],
/// returns the generic arguments to the [checker] [Type] if there are any.
///
/// If the [checker] [Type] doesn't have generic arguments, `null` is returned.
List<DartType> typeArgumentsOf(DartType type, TypeChecker checker) {
  final implementation = _getImplementationType(type, checker) as InterfaceType;

  return implementation?.typeArguments;
}

DartType _getImplementationType(DartType type, TypeChecker checker) {
  if (checker.isExactlyType(type)) return type;

  if (type is InterfaceType) {
    final match = [type.interfaces, type.mixins]
        .expand((e) => e)
        .map((type) => _getImplementationType(type, checker))
        .firstWhere((value) => value != null, orElse: () => null);

    if (match != null) {
      return match;
    }

    if (type.superclass != null) {
      return _getImplementationType(type.superclass, checker);
    }
  }
  return null;
}

/// Returns a quoted String literal for [value] that can be used in generated
/// Dart code.
String escapeDartString(String value) {
  var hasSingleQuote = false;
  var hasDoubleQuote = false;
  var hasDollar = false;
  var canBeRaw = true;

  value = value.replaceAllMapped(_escapeRegExp, (match) {
    final value = match[0];
    if (value == "'") {
      hasSingleQuote = true;
      return value;
    } else if (value == '"') {
      hasDoubleQuote = true;
      return value;
    } else if (value == r'$') {
      hasDollar = true;
      return value;
    }

    canBeRaw = false;
    return _escapeMap[value] ?? _getHexLiteral(value);
  });

  if (!hasDollar) {
    if (hasSingleQuote) {
      if (!hasDoubleQuote) {
        return '"$value"';
      }
      // something
    } else {
      // trivial!
      return "'$value'";
    }
  }

  if (hasDollar && canBeRaw) {
    if (hasSingleQuote) {
      if (!hasDoubleQuote) {
        // quote it with single quotes!
        return 'r"$value"';
      }
    } else {
      // quote it with single quotes!
      return "r'$value'";
    }
  }

  // The only safe way to wrap the content is to escape all of the
  // problematic characters - `$`, `'`, and `"`
  final string = value.replaceAll(_dollarQuoteRegexp, r'\');
  return "'$string'";
}

final _dollarQuoteRegexp = RegExp(r"""(?=[$'"])""");

/// A [Map] between whitespace characters & `\` and their escape sequences.
const _escapeMap = {
  '\b': r'\b', // 08 - backspace
  '\t': r'\t', // 09 - tab
  '\n': r'\n', // 0A - new line
  '\v': r'\v', // 0B - vertical tab
  '\f': r'\f', // 0C - form feed
  '\r': r'\r', // 0D - carriage return
  '\x7F': r'\x7F', // delete
  r'\': r'\\' // backslash
};

final _escapeMapRegexp = _escapeMap.keys.map(_getHexLiteral).join();

/// A [RegExp] that matches whitespace characters that should be escaped and
/// single-quote, double-quote, and `$`
final _escapeRegExp = RegExp('[\$\'"\\x00-\\x07\\x0E-\\x1F$_escapeMapRegexp]');

/// Given single-character string, return the hex-escaped equivalent.
String _getHexLiteral(String input) {
  final rune = input.runes.single;
  final value = rune.toRadixString(16).toUpperCase().padLeft(2, '0');
  return '\\x$value';
}

/// Returns a [Set] of all instance [FieldElement] items for [element] and
/// super classes, sorted first by their location in the inheritance hierarchy
/// (super first) and then by their location in the source file.
Set<FieldElement> createSortedFieldSet(ClassElement element) {
  // Get all of the fields that need to be assigned
  // TODO: support overriding the field set with an annotation option
  final fieldsList = element.fields.where((e) => !e.isStatic).toList();

  final manager = InheritanceManager3(); // ignore: deprecated_member_use

  for (var v in manager.getInheritedMap(element.thisType).values) {
    assert(v is! FieldElement);
    if (_dartCoreObjectChecker.isExactly(v.enclosingElement)) {
      continue;
    }

    if (v is PropertyAccessorElement && v.variable is FieldElement) {
      fieldsList.add(v.variable as FieldElement);
    }
  }

  // Sort these in the order in which they appear in the class
  // Sadly, `classElement.fields` puts properties after fields
  fieldsList.sort(_sortByLocation);

  return fieldsList.toSet();
}

int _sortByLocation(FieldElement a, FieldElement b) {
  final checkerA =
      TypeChecker.fromStatic((a.enclosingElement as ClassElement).thisType);

  if (!checkerA.isExactly(b.enclosingElement)) {
    // in this case, you want to prioritize the enclosingElement that is more
    // "super".

    if (checkerA.isSuperOf(b.enclosingElement)) {
      return -1;
    }

    final checkerB =
        TypeChecker.fromStatic((b.enclosingElement as ClassElement).thisType);

    if (checkerB.isSuperOf(a.enclosingElement)) {
      return 1;
    }
  }

  /// Returns the offset of given field/property in its source file – with a
  /// preference for the getter if it's defined.
  int _offsetFor(FieldElement e) {
    if (e.getter != null && e.getter.nameOffset != e.nameOffset) {
      assert(e.nameOffset == -1);
      return e.getter.nameOffset;
    }
    return e.nameOffset;
  }

  return _offsetFor(a).compareTo(_offsetFor(b));
}

const _dartCoreObjectChecker = TypeChecker.fromRuntime(Object);

/// Writes the invocation of the default constructor – `new Class(...)` for the
/// type defined in [classElement] to the provided [buffer].
///
/// If an parameter is required to invoke the constructor,
/// [availableConstructorParameters] is checked to see if it is available. If
/// [availableConstructorParameters] does not contain the parameter name,
/// an [UnsupportedError] is thrown.
///
/// To improve the error details, [unavailableReasons] is checked for the
/// unavailable constructor parameter. If the value is not `null`, it is
/// included in the [UnsupportedError] message.
///
/// [writeableFields] are also populated, but only if they have not already
/// been defined by a constructor parameter with the same name.
///
/// Set set of all constructor parameters and and fields that are populated is
/// returned.
Set<String> writeConstructorInvocation(
    StringBuffer buffer,
    ClassElement classElement,
    Iterable<String> availableConstructorParameters,
    Iterable<String> writeableFields,
    Map<String, String> unavailableReasons,
    String Function(String paramOrFieldName, {ParameterElement ctorParam})
        deserializeForField) {
  final className = classElement.displayName;

  var ctor = classElement.unnamedConstructor;
  if (ctor == null) {
    if (classElement.constructors.length == 1) {
      ctor = classElement.constructors.single;
    } else {
      // TODO: allow specifying the target constructor
      throw InvalidGenerationSourceError(
        'Could not pick a constructor to use.',
        element: classElement,
      );
    }
  }

  final usedCtorParamsAndFields = <String>{};
  final constructorArguments = <ParameterElement>[];
  final namedConstructorArguments = <ParameterElement>[];

  for (var arg in ctor.parameters) {
    if (!availableConstructorParameters.contains(arg.name)) {
      if (arg.isPositional) {
        var msg = 'Cannot populate the required constructor '
            'argument: ${arg.displayName}.';

        final additionalInfo = unavailableReasons[arg.name];

        if (additionalInfo != null) {
          msg = '$msg $additionalInfo';
        }

        throw InvalidGenerationSourceError(msg, element: ctor);
      }

      continue;
    }

    // TODO: validate that the types match!
    if (arg.isNamed) {
      namedConstructorArguments.add(arg);
    } else {
      constructorArguments.add(arg);
    }
    usedCtorParamsAndFields.add(arg.name);
  }

  // fields that aren't already set by the constructor and that aren't final
  final remainingFieldsForInvocationBody =
      writeableFields.toSet().difference(usedCtorParamsAndFields);

  final ctorName = ctor.name.isEmpty ? '' : '.${ctor.name}';

  //
  // Generate the static factory method
  //
  buffer
    ..write('$className$ctorName(')
    ..writeAll(
        constructorArguments.map((paramElement) =>
            deserializeForField(paramElement.name, ctorParam: paramElement)),
        ', ');
  if (constructorArguments.isNotEmpty && namedConstructorArguments.isNotEmpty) {
    buffer.write(', ');
  }
  buffer
    ..writeAll(namedConstructorArguments.map((paramElement) {
      final value =
          deserializeForField(paramElement.name, ctorParam: paramElement);
      return '${paramElement.name}: $value';
    }), ', ')
    ..write(')');
  if (remainingFieldsForInvocationBody.isEmpty) {
    buffer.writeln(';');
  } else {
    for (var field in remainingFieldsForInvocationBody) {
      buffer
        ..writeln()
        ..write('      ..$field = ')
        ..write(deserializeForField(field));
      usedCtorParamsAndFields.add(field);
    }
    buffer.writeln(';');
  }
  buffer.writeln();

  return usedCtorParamsAndFields;
}

extension DartTypeExtension on DartType {
  bool isAssignableTo(DartType other) =>
      // If the library is `null`, treat it like dynamic => `true`
      element.library == null ||
      element.library.typeSystem.isAssignableTo(this, other);
}
