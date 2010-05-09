namespace UnityScript.Core

import Boo.Lang.Compiler.Ast

static class UnityScriptCompilerErrors:

	def SemicolonExpected(location as LexicalInfo):
		return CreateError("UCE0001", location, "';' expected. Insert a semicolon at the end.")
		
	def UnknownPragma(location as LexicalInfo, pragma as string):
		return CreateError("UCE0002", location, "Unknown pragma '${pragma}'")
		
	def InvalidPropertySetter(location as LexicalInfo):
		return CreateError("UCE0003", location, "Property setter must have a single argument named 'value'")
		
	def InvalidPropertyGetter(location as LexicalInfo):
		return CreateError("UCE0004", location, "Property getter cannot declare any arguments.")
		
	def InterfaceExpected(location as LexicalInfo, typeName as string):
		return CreateError("UCE0005", location, "'${typeName}' is not an interface.")
	
	def ClassExpected(location as LexicalInfo, typeName as string):
		return CreateError("UCE0006", location, "'${typeName}' is not a class.")
		
	private def CreateError(code as string, location as LexicalInfo, message as string):
		return Boo.Lang.Compiler.CompilerError(code, location, message, null)
		