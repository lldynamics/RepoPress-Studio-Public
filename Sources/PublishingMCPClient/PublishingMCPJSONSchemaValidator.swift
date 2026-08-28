import PublishingAICore

/// A conservative structural validator for the JSON Schema subset accepted at
/// the model-tool boundary. It validates keyword shapes recursively; it is not
/// a data-instance validator.
enum PublishingMCPJSONSchemaValidator {
  private static let supportedTypes: Set<String> = [
    "array", "boolean", "integer", "null", "number", "object", "string",
  ]

  static func isSupportedRootSchema(_ value: AIStructuredOutputJSONValue) -> Bool {
    guard case .object(let object) = value,
      case .string("object")? = object["type"]
    else {
      return false
    }
    return isSchema(value)
  }

  private static func isSchema(_ value: AIStructuredOutputJSONValue) -> Bool {
    if case .bool = value { return true }
    guard case .object(let object) = value else { return false }

    for (keyword, keywordValue) in object {
      switch keyword {
      case "$id", "$schema", "$ref", "$anchor", "$dynamicRef", "$dynamicAnchor",
        "$comment", "title", "description", "format", "pattern", "contentEncoding",
        "contentMediaType":
        guard case .string = keywordValue else { return false }

      case "type":
        guard isTypeDeclaration(keywordValue) else { return false }

      case "$defs", "definitions", "properties", "patternProperties", "dependentSchemas":
        guard isSchemaMap(keywordValue) else { return false }

      case "additionalProperties", "unevaluatedProperties", "propertyNames", "contains",
        "not", "if", "then", "else", "unevaluatedItems", "contentSchema":
        guard isSchema(keywordValue) else { return false }

      case "items":
        guard isSchema(keywordValue) || isSchemaArray(keywordValue, allowEmpty: true) else {
          return false
        }

      case "prefixItems", "allOf", "anyOf", "oneOf":
        guard isSchemaArray(keywordValue, allowEmpty: false) else { return false }

      case "required":
        guard isUniqueStringArray(keywordValue, allowEmpty: true) else { return false }

      case "dependentRequired":
        guard case .object(let dependencies) = keywordValue,
          dependencies.values.allSatisfy({ isUniqueStringArray($0, allowEmpty: true) })
        else {
          return false
        }

      case "dependencies":
        guard case .object(let dependencies) = keywordValue,
          dependencies.values.allSatisfy({
            isSchema($0) || isUniqueStringArray($0, allowEmpty: true)
          })
        else {
          return false
        }

      case "multipleOf":
        guard case .number(let number) = keywordValue, number.isFinite, number > 0 else {
          return false
        }

      case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
        guard case .number(let number) = keywordValue, number.isFinite else { return false }

      case "minLength", "maxLength", "minItems", "maxItems", "minContains", "maxContains",
        "minProperties", "maxProperties":
        guard isNonnegativeInteger(keywordValue) else { return false }

      case "uniqueItems", "readOnly", "writeOnly", "deprecated":
        guard case .bool = keywordValue else { return false }

      case "enum":
        guard case .array(let values) = keywordValue, !values.isEmpty else { return false }

      case "const", "default":
        continue

      case "examples":
        guard case .array = keywordValue else { return false }

      default:
        // Unknown keywords can change provider interpretation, so this adapter
        // requires an explicit future update instead of forwarding them.
        return false
      }
    }
    return true
  }

  private static func isTypeDeclaration(_ value: AIStructuredOutputJSONValue) -> Bool {
    switch value {
    case .string(let type):
      return supportedTypes.contains(type)
    case .array(let values):
      let types = values.compactMap { value -> String? in
        guard case .string(let type) = value else { return nil }
        return type
      }
      return !types.isEmpty && types.count == values.count
        && Set(types).count == types.count
        && types.allSatisfy(supportedTypes.contains)
    default:
      return false
    }
  }

  private static func isSchemaMap(_ value: AIStructuredOutputJSONValue) -> Bool {
    guard case .object(let schemas) = value else { return false }
    return schemas.values.allSatisfy(isSchema)
  }

  private static func isSchemaArray(
    _ value: AIStructuredOutputJSONValue,
    allowEmpty: Bool
  ) -> Bool {
    guard case .array(let schemas) = value,
      allowEmpty || !schemas.isEmpty
    else {
      return false
    }
    return schemas.allSatisfy(isSchema)
  }

  private static func isUniqueStringArray(
    _ value: AIStructuredOutputJSONValue,
    allowEmpty: Bool
  ) -> Bool {
    guard case .array(let values) = value,
      allowEmpty || !values.isEmpty
    else {
      return false
    }
    let strings = values.compactMap { value -> String? in
      guard case .string(let string) = value else { return nil }
      return string
    }
    return strings.count == values.count && Set(strings).count == strings.count
  }

  private static func isNonnegativeInteger(_ value: AIStructuredOutputJSONValue) -> Bool {
    guard case .number(let number) = value,
      number.isFinite,
      number >= 0,
      number.rounded(.towardZero) == number
    else {
      return false
    }
    return true
  }
}
