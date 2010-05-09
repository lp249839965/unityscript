namespace UnityScript.Steps

import Boo.Lang.Compiler
import Boo.Lang.Compiler.Ast
import Boo.Lang.Compiler.TypeSystem
import Boo.Lang.Compiler.TypeSystem.Internal
import Boo.Lang.Compiler.Steps

class ProcessUnityScriptMethods(ProcessMethodBodiesWithDuckTyping):
	
	static final IEnumerable_GetEnumerator = Types.IEnumerable.GetMethod("GetEnumerator");
		
	static final IEnumerator_MoveNext = Types.IEnumerator.GetMethod("MoveNext");
		
	static final IEnumerator_get_Current = Types.IEnumerator.GetProperty("Current").GetGetMethod();
	
	_StartCoroutine as IMethod
	_UnityRuntimeServices_GetEnumerator as IMethod
	_UnityRuntimeServices_Update as IMethod
	_UnityRuntimeServices_GetTypeOf as IMethod
	
	_strict = false
	
	override def Initialize(context as CompilerContext):
		super(context)
				
		// don't transform
		//     foo == null
		// into:
		//     foo is null
		// but into:
		//     foo.Equals(null)						
		self.OptimizeNullComparisons = false
		self._StartCoroutine = NameResolutionService.ResolveMethod(
													UnityScriptTypeSystem.ScriptBaseType,
													"StartCoroutine_Auto")		
		self._UnityRuntimeServices_GetEnumerator = ResolveUnityRuntimeMethod("GetEnumerator")													
		self._UnityRuntimeServices_Update = ResolveUnityRuntimeMethod("Update")
		self._UnityRuntimeServices_GetTypeOf = ResolveUnityRuntimeMethod("GetTypeOf")
		
	def ResolveUnityRuntimeMethod(name as string):
		return NameResolutionService.ResolveMethod(
					TypeSystemServices.Map(UnityScript.Lang.UnityRuntimeServices),
					name)
		
	UnityScriptTypeSystem as UnityScript.Steps.UnityScriptTypeSystem:
		get: return self.TypeSystemServices
			
	UnityScriptParameters as UnityScript.UnityScriptCompilerParameters:
		get: return _context.Parameters
		
	override def GetGeneratorReturnType(generator as InternalMethod):
		return TypeSystemServices.IEnumeratorType
			
	override def IsDuckTyped(e as Expression):
		if _strict: return false
		return super(e)
		
	override def IsDuckTyped(member as IMember):
		if _strict: return false
		return super(member)
		
	override protected def MemberNotFound(node as MemberReferenceExpression, ns as INamespace):
		if (not _strict) and (UnityScriptParameters.Expando or super.IsDuckTyped(node.Target)):
			BindQuack(node);
			return
		super(node, ns)
			
	override def OnModule(module as Module):           
		Parameters.Strict = _strict = module.ContainsAnnotation("strict")
		super(module)
		
	override def OnMethod(node as Method):
		super(node)
		return if Parameters.OutputType == CompilerOutputType.Library
		CheckEntryPoint(node)
		
	def CheckEntryPoint(node as Method):
		if not node.IsStatic: return
		if not node.IsPublic: return
		if node.Name != "Main": return
		if GetType(node.ReturnType) is not TypeSystemServices.VoidType: return
		
		ContextAnnotations.SetEntryPoint(_context, node)
		
	override def ProcessAutoLocalDeclaration(node as BinaryExpression, reference as ReferenceExpression):
		if _strict and not IsCompilerGenerated(reference):
			EmitUnknownIdentifierError(reference, reference.Name)
		else:
			super(node, reference)
			
	def IsCompilerGenerated(reference as ReferenceExpression):
		return reference.Name.Contains('$')
		
	override protected def ProcessBuiltinInvocation(function as BuiltinFunction, node as MethodInvocationExpression):
		if function is UnityScriptTypeSystem.UnityScriptEval:
			ProcessEvalInvocations.Mark(_currentMethod.Method)
			BindExpressionType(node, TypeSystemServices.ObjectType)
			return
		if function is UnityScriptTypeSystem.UnityScriptTypeof:
			ProcessTypeofBuiltin(node);
			return
		super(function, node)
		
	private def ProcessTypeofBuiltin(node as MethodInvocationExpression):
		if node.Arguments.Count != 1:
			Error(node, CompilerError("UCE0001", node.Target.LexicalInfo, "'typeof' takes a single argument.", null))
			return
		
		type = TypeSystemServices.GetOptionalEntity(node.Arguments[0]) as IType
		if type is not null:
			node.ParentNode.Replace(node, CodeBuilder.CreateTypeofExpression(type))
			return
			
		node.Target = CodeBuilder.CreateReference(_UnityRuntimeServices_GetTypeOf)
		BindExpressionType(node, TypeSystemServices.TypeType)
				
		
	override protected def ProcessMethodInvocation(node as MethodInvocationExpression, targetEntity as IEntity):
	"""
	Automatically detects coroutine invocations in assignments and as standalone
	expressions and generates StartCoroutine invocations.
	"""
		super(node, targetEntity)
		
		if not IsPossibleStartCoroutineInvocation(node):
			return		

		method as IMethod = targetEntity
		if method is null or method.IsStatic: return		
		
		tss = self.UnityScriptTypeSystem
		if not tss.IsScriptType(method.DeclaringType): return		
		if not tss.IsGenerator(method): return
		
		parentNode = node.ParentNode
		parentNode.Replace(
			node,
			CodeBuilder.CreateMethodInvocation(
				cast(MemberReferenceExpression, node.Target).Target.CloneNode(),
				_StartCoroutine,
				node))
				
	override def ProcessStaticallyTypedAssignment(node as BinaryExpression):
		TryToResolveAmbiguousAssignment(node)		
		ApplyImplicitArrayConversion(node)
		ValidateAssignment(node)
		BindExpressionType(node, GetExpressionType(node.Right))
		
	def ApplyImplicitArrayConversion(node as BinaryExpression):
		left = GetExpressionType(node.Left)
		if not left.IsArray: return
				
		right = GetExpressionType(node.Right)
		if right is not TypeSystemServices.Map(UnityScript.Lang.Array): return

		node.Right = CodeBuilder.CreateCast(left, 
						CodeBuilder.CreateMethodInvocation(
							node.Right,
							ResolveMethod(right, "ToBuiltin"),
							CodeBuilder.CreateTypeofExpression(left.GetElementType())))
				
	override def OnForStatement(node as ForStatement):
		assert 1 == len(node.Declarations)
		Visit(node.Iterator)
		if NeedsUpdateableIteration(node):
			ProcessUpdateableIteration(node)
		else:
			ProcessNormalIteration(node)

	def ProcessNormalIteration(node as ForStatement):
		node.Iterator = ProcessIterator(node.Iterator, node.Declarations)
		VisitForStatementBlock(node)
		
	def ProcessUpdateableIteration(node as ForStatement):
		newIterator = CodeBuilder.CreateMethodInvocation(_UnityRuntimeServices_GetEnumerator, node.Iterator)
		newIterator.LexicalInfo = LexicalInfo(node.Iterator.LexicalInfo)
		node.Iterator = newIterator
		ProcessDeclarationForIterator(node.Declarations[0], TypeSystemServices.ObjectType)
		VisitForStatementBlock(node)
		TransformIteration(node)

	def TransformIteration(node as ForStatement):
		iterator = CodeBuilder.DeclareLocal(
						_currentMethod.Method,
						_context.GetUniqueName("iterator"),
						TypeSystemServices.IEnumeratorType)
		iterator.IsUsed = true
		body = Block(node.LexicalInfo)
		body.Add(
			CodeBuilder.CreateAssignment(
				node.LexicalInfo,
				CodeBuilder.CreateReference(iterator),
				node.Iterator))
				
		// while __iterator.MoveNext():
		ws = WhileStatement(node.LexicalInfo)
		ws.Condition = CodeBuilder.CreateMethodInvocation(
						CodeBuilder.CreateReference(iterator),
						IEnumerator_MoveNext)
			
		current = CodeBuilder.CreateMethodInvocation(
							CodeBuilder.CreateReference(iterator),
							IEnumerator_get_Current)
			
		//	item = __iterator.Current
		loopVariable as InternalLocal = TypeSystemServices.GetEntity(node.Declarations[0])
		ws.Block.Add(
				CodeBuilder.CreateAssignment(
					node.LexicalInfo,
					CodeBuilder.CreateReference(loopVariable),
					current))
		ws.Block.Add(node.Block)			
		
		LoopVariableUpdater(self, _context, iterator, loopVariable).Visit(node)
		
		body.Add(ws)
		node.ParentNode.Replace(node, body)
		
	def NeedsUpdateableIteration(node as ForStatement):
		iteratorType = GetExpressionType(node.Iterator)
		if iteratorType.IsArray: return false
		return true
		
	class LoopVariableUpdater(DepthFirstVisitor):
		
		_parent as ProcessUnityScriptMethods
		_context as CompilerContext
		_iteratorVariable as IEntity
		_loopVariable as IEntity
		_found as bool
		
		def constructor(parent as ProcessUnityScriptMethods, context as CompilerContext, iteratorVariable as IEntity, loopVariable as IEntity):
			_parent = parent
			_context = context
			_iteratorVariable = iteratorVariable
			_loopVariable = loopVariable
			
		override def OnExpressionStatement(node as ExpressionStatement):
			_found = false
			Visit(node.Expression)
			if not _found: return
			
			parentNode = node.ParentNode
			
			codeBuilder = _context.CodeBuilder
			block = Block(node.LexicalInfo)
			block.Add(node)
			block.Add(
				codeBuilder.CreateMethodInvocation(
					_parent._UnityRuntimeServices_Update, 
					codeBuilder.CreateReference(_iteratorVariable),
					codeBuilder.CreateReference(_loopVariable)))

			parentNode.Replace(node, block)
			
		override def OnReferenceExpression(node as ReferenceExpression):
			if _found: return
			
			referent = _context.TypeSystemServices.GetOptionalEntity(node)
			_found = referent is _loopVariable