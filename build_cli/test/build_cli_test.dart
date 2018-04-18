// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/src/string_source.dart';
import 'package:dart_style/dart_style.dart' as dart_style;
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

import 'package:build_cli/build_cli.dart';

import 'analysis_utils.dart';
import 'test_utils.dart';

void main() {
  final generator = const CliGenerator();
  CompilationUnit compUnit;

  setUpAll(() async {
    compUnit = await _getCompilationUnitForString(getPackagePath());
  });

  Future<String> runForElementNamed(String name) async {
    var library = new LibraryReader(compUnit.element.library);
    var element = library.allElements
        .singleWhere((e) => e.name == name, orElse: () => null);
    if (element == null) {
      fail('Could not find element `$name`.');
    }
    var annotation = generator.typeChecker.firstAnnotationOf(element);
    var generated = await generator.generateForAnnotatedElement(
        element, new ConstantReader(annotation), null);

    return _formatter.format(generated);
  }

  void testOutput(String testName, String element, expected) {
    test(testName, () async {
      var actual = await runForElementNamed(element);
      printOnFailure(['`' * 72, actual, '`' * 72].join('\n'));
      expect(actual, expected);
    });
  }

  testOutput('just empty', 'Empty', r'''
Empty _$parseEmptyResult(ArgResults result) {
  return new Empty();
}

ArgParser _$populateEmptyParser(ArgParser parser) => parser;

final _$parserForEmpty = _$populateEmptyParser(new ArgParser());

Empty parseEmpty(List<String> args) {
  var result = _$parserForEmpty.parse(args);
  return _$parseEmptyResult(result);
}
''');

  group('non-classes', () {
    test('const field', () async {
      expect(
          runForElementNamed('theAnswer'),
          throwsInvalidGenerationSourceError(
              'Generator cannot target `theAnswer`.'
              ' `@CliOptions` can only be applied to a class.',
              'Remove the `@CliOptions` annotation from `theAnswer`.'));
    });

    test('method', () async {
      expect(
          runForElementNamed('annotatedMethod'),
          throwsInvalidGenerationSourceError(
              'Generator cannot target `annotatedMethod`.'
              ' `@CliOptions` can only be applied to a class.',
              'Remove the `@CliOptions` annotation from `annotatedMethod`.'));
    });
  });
  group('unknown types', () {
    test('in constructor arguments', () async {
      expect(
          runForElementNamed('UnknownCtorParamType'),
          throwsInvalidGenerationSourceError(
              'At least one constructor argument has an invalid type: `number`.',
              'Check names and imports.'));
    });

    test('in fields', () async {
      expect(
          runForElementNamed('UnknownFieldType'),
          throwsInvalidGenerationSourceError(
              'At least one field has an invalid type: `number`.',
              'Check names and imports.'));
    });
  });
}

final _formatter = new dart_style.DartFormatter();

Future<CompilationUnit> _getCompilationUnitForString(String projectPath) async {
  var filePath = p.join(getPackagePath(), 'test', 'src', 'test_input.dart');
  var source =
      new StringSource(new File(filePath).readAsStringSync(), 'test content');

  var context = await getAnalysisContextForProjectPath(projectPath);

  var libElement = context.computeLibraryElement(source);
  return context.resolveCompilationUnit(source, libElement);
}