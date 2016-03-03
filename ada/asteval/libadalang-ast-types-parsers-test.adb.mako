## vim: ft=makoada

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Ada.Wide_Wide_Characters.Handling; use Ada.Wide_Wide_Characters.Handling;

with Langkit_Support.Diagnostics; use Langkit_Support.Diagnostics;
with Langkit_Support.Text;        use Langkit_Support.Text;

package body Libadalang.AST.Types.Parsers.Test is

   function "+" (S : String) return Unbounded_String
      renames To_Unbounded_String;
   function "+" (S : Unbounded_String) return String
      renames To_String;

   function "+" (S : Wide_Wide_String) return Unbounded_Wide_Wide_String
      renames To_Unbounded_Wide_Wide_String;
   function "+" (S : Unbounded_Wide_Wide_String) return Wide_Wide_String
      renames To_Wide_Wide_String;

   type Eval_Result_Array is array (Natural range <>) of Eval_Result;

   ---------------
   -- Kind_Name --
   ---------------

   function Kind_Name (K : Eval_Result_Kind) return String is
     (case K is
      when Boolean_Value  => "boolean",
      when Integer_Value  => "integer",

      % for cls in ctx.sorted_types(ctx.enum_types):
         when ${enum_for_type(cls)} => "${cls.name()} enumeration",
      % endfor

      % for cls in ctx.sorted_types(ctx.struct_types):
         when ${enum_for_type(cls)} => "${cls.name()} structure",
      % endfor

      % for cls in ctx.sorted_types(ctx.array_types):
         when ${enum_for_type(cls)} => "${cls.name()} array",
      % endfor

      when Ada_Node_Value          => "AST node",
      when Ada_Node_Iterator_Value => "AST node iterator",
      when Token_Value             => "token",
      when Lexical_Env_Value       => "lexical environment",
      when Field_Access_Value      => "access to field requiring arguments",
      when Find_Builtin_Value      => ".Find builtin method",
      when Symbol_Value       => "symbol",
      when Error_Value             => raise Program_Error);

   function Create (V : Eval_Result_Access) return Eval_Result;
   --  Initialize the refcount for V and return a reference to it

   ------------
   -- Create --
   ------------

   function Create (V : Eval_Result_Access) return Eval_Result is
   begin
      V.Ref_Count := 1;
      return (Ada.Finalization.Controlled with
              Value => V);
   end Create;

   ----------------------
   -- Parse_Expression --
   ----------------------

   function Parse_Expression (Buffer : String) return Expression is
      Expr   : Expression := new Expression_Type;
      Parser : Parser_Type;
   begin
      Initialize (Expr.TDH, Expr.Symbols);
      Parser := Create_From_Buffer (Buffer, "", Expr.TDH'Unrestricted_Access);
      Parser.Mem_Pool := Expr.Pool;

      Expr.Root := Ada_Node (Parse_Expression (Parser));
      if not Parser.Diagnostics.Is_Empty then
         Put_Line ("Parsing failed:");
         for D of Parser.Diagnostics loop
            Put_Line (To_Pretty_String (D));
         end loop;
         Destroy (Expr);
      end if;

      return Expr;
   end Parse_Expression;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (E : in out Expression) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Expression_Type, Expression);
   begin
      Free (E.TDH);
      Destroy (E.Symbols);
      Free (E);
   end Destroy;

   ----------
   -- Eval --
   ----------

   function Eval (E : Expression; Root : Ada_Node) return Eval_Result is

      --  For convenience, all expression evaluation code is embedded in this
      --  function. On the other hand, this root Eval function is basically
      --  just a wrapper for the inner Eval one. This inner function dispatches
      --  the evaluation to other Eval_* functions according to the type of the
      --  root DSL expression node it is provided.

      Evaluation_Error : exception;
      --  Internal exception: see Raise_Error

      Error : Eval_Result_Record (Error_Value);
      --  Internal error holder: see Raise_Error

      procedure Raise_Error
        (Expr    : access Ada_Node_Type'Class;
         Message : String)
         with No_Return => True;
      --  When one of the Eval* functions below notifies an error in the input
      --  expression (invalid identifier, out-of-bounds access, etc.), it must
      --  call Raise_Error in order to abort the expression evaluation and
      --  return to the caller the Error_Value Eval_Result object that
      --  describes what happened.
      --
      --  The implementation is straightforward: Raise_Error creates the
      --  Eval_Result instance and stores it in the Error local variable. Then,
      --  it raises a Evaluation_Error exception, which is supposed to be
      --  caught in the top-level Eval function. This Eval function discards
      --  processing and just returns the Error variable.

      function Eval (Expr : access Ada_Node_Type'Class) return Eval_Result;
      --  Evaluation entry point for arbitrary sub-expressions, return the
      --  corresponding result or invoke Raise_Error.

      function Eval_Call (Expr : Call_Expr) return Eval_Result;
      --  Return a call expression evaluation (method invocation or array
      --  subscript) or invoke Raise_Error.

      function Eval_Find
        (Expr   : Ada_Node;
         Root   : Ada_Node;
         Params : Param_List)
         return Eval_Result;
      --  Given a Expr sub-expression which is a Find method invocation, the
      --  Root node used as the root for the AST node lookup and Params, the
      --  Param_List associated to this Find method call, return the evaluation
      --  of the Find method or invoke Raise_Error.

      function Eval_Identifier (Expr : Identifier) return Eval_Result;
      --  Return a mere identifier expression evaluation or invoke Raise_Error

      function Eval_Prefix (Expr : Prefix) return Eval_Result;
      --  Return a prefix (X.Y) expression evaluation or invoke Raise_Error

      ----------
      -- Eval --
      ----------

      function Eval (Expr : access Ada_Node_Type'Class) return Eval_Result is
      begin
         case Kind (Expr) is
         when Call_Expr_Kind =>
            return Eval_Call (Call_Expr (Expr));
         when Identifier_Kind =>
            return Eval_Identifier (Identifier (Expr));
         when Num_Literal_Kind =>
            declare
               Text : constant Text_Type :=
                  Num_Literal (Expr).F_Tok.Text.all;
            begin
               return Create (new Eval_Result_Record'
                 (Kind      => Integer_Value,
                  Ref_Count => <>,
                  Int       => Integer'Value (Image (Text))));
            end;
         when Prefix_Kind =>
            return Eval_Prefix (Prefix (Expr));
         when others =>
            Raise_Error (Expr, "Unhandled expression: " & Kind_Name (Expr));
         end case;
      end Eval;

      ---------------
      -- Eval_Call --
      ---------------

      function Eval_Call (Expr : Call_Expr) return Eval_Result is

         function Get_Single_Index (Params : Param_List) return Integer;
         --  If Params is anything else than a list of exactly one integer
         --  parameter without any designator, raise an error. Otherwise,
         --  evaluate this integer and return it.

         function Eval_Params (Params : Param_List) return Eval_Result_Array;
         --  Evaluate each actual in Params and return an array for these.
         --  This raises an error if any parameter has a designator (we don't
         --  support them).

         ----------------------
         -- Get_Single_Index --
         ----------------------

         function Get_Single_Index (Params : Param_List) return Integer is
            Index_Expr : Ada_Node;
            Exists     : Boolean;
         begin
            --  Invoke Raise_Error if we have more or less that 1 parameter in
            --  Params.

            if Child_Count (Params) /= 1 then
               Raise_Error (Params, "Exactly one index is expected");
            end if;

            Params.F_Params.Get_Child (0, Exists, Index_Expr);
            pragma Assert (Exists);

            --  Likewise if the kind of the parameter is unexpected or if
            --  it's not a simple form (i.e. X => Y instead of Y).

            if Kind (Index_Expr) /= Param_Assoc_Kind then
               Raise_Error (Params,
                            "Invalid index: " & Kind_Name (Index_Expr));
            elsif Param_Assoc (Index_Expr).F_Designator /= null then
               Raise_Error (Params, "No designator allowed for subscript");
            end if;

            --  Now, try to get an integer out of this expression

            Index_Expr := Ada_Node (Param_Assoc (Index_Expr).F_Expr);
            declare
               Index : constant Eval_Result := Eval (Index_Expr);
            begin
               if Index.Value.Kind /= Integer_Value then
                  Raise_Error (Index_Expr,
                               "Invalid index: "
                               & Kind_Name (Index.Value.Kind));
               end if;
               return Index.Value.Int;
            end;
         end Get_Single_Index;

         -----------------
         -- Eval_Params --
         -----------------

         function Eval_Params (Params : Param_List) return Eval_Result_Array is
            Result : Eval_Result_Array (0 .. Params.F_Params.Child_Count - 1);
         begin
            for I in Result'Range loop
               declare
                  Assoc  : Ada_Node;
                  Exists : Boolean;
               begin
                  Params.F_Params.Get_Child (I, Exists, Assoc);
                  pragma Assert (Exists);

                  if Kind (Assoc) /= Param_Assoc_Kind then
                     Raise_Error
                       (Assoc, "Invalid parameter: " & Kind_Name (Assoc));
                  elsif Param_Assoc (Assoc).F_Designator /= null then
                     Raise_Error (Assoc, "Designator not allowed here");
                  end if;

                  Result (I) := Eval (Param_Assoc (Assoc).F_Expr);
               end;
            end loop;
            return Result;
         end Eval_Params;

         Name   : constant Eval_Result := Eval (Expr.F_Name);
         Params : Param_List;
      begin
         --  This is more like a sanity check: for Call_Expr nodes, we don't
         --  expect anything else than a Param_List suffix.

         if Kind (Expr.F_Suffix) /= Param_List_Kind then
            Raise_Error (Expr,
                         "Invalid " & Kind_Name (Expr.F_Suffix)
                         & " suffix (ParamList expected)");
         end if;

         Params := Param_List (Expr.F_Suffix);

         --  What this expression really do depend on the kind of the name
         --  (aka. "prefix"): it can be either a call or an array subscript.

         case Name.Value.Kind is

            --  If it's an array, try to fetch the Nth element

            % for cls in ctx.sorted_types(ctx.array_types):
               when ${enum_for_type(cls)} =>
                  declare
                     Index  : Integer := Get_Single_Index (Params);
                     A      : ${cls.api_name()} renames
                                 Name.Value.${field_for_type(cls)}.Items;
                  begin
                     if Index not in A'Range then
                        Raise_Error
                          (Expr,
                           "Out of bounds index: "
                           & Integer'Image (Index)
                           & " not in "
                           & Integer'Image (A'First) & " .. "
                           & Integer'Image (A'Last));
                     end if;
                     return Create (new Eval_Result_Record'
                       (Kind      => ${enum_for_type(cls.element_type())},
                        Ref_Count => <>,
                        ${field_for_type(cls.element_type())} =>
                           A (Index)));
                  end;
            % endfor

            --  If it's an AST node, try to fetch the Nth child

            when Ada_Node_Value =>
               declare
                  Index  : constant Integer := Get_Single_Index (Params);
                  Result : Ada_Node;
                  Exists : Boolean;
               begin
                  Name.Value.Node.Get_Child (Index, Exists, Result);
                  if not Exists then
                     Raise_Error
                       (Expr,
                        "Out of bounds index: "
                        & Integer'Image (Index)
                        & " not in "
                        & Integer'Image (0) & " .. "
                        & Integer'Image (Child_Count (Name.Value.Node) - 1));
                  end if;
                  return Create (new Eval_Result_Record'
                    (Kind      => Ada_Node_Value,
                     Ref_Count => <>,
                     Node      => Result));
               end;

            --  If it's an AST node iterator, try to fetch the Nth yielded node

            when Ada_Node_Iterator_Value =>
               declare
                  It       : Ada_Node_Iterators.Iterator'Class renames
                     Name.Value.Node_Iter.all;
                  Index    : constant Integer := Get_Single_Index (Params);
                  Result   : Ada_Node;
                  Has_Next : Boolean := True;
               begin
                  if Index < 0 then
                     Raise_Error
                       (Params,
                        "Invalid iterator element index: "
                        & Integer'Image (Index));
                  end if;

                  for I in 0 .. Index loop
                     It.Next (Has_Next, Result);
                     if not Has_Next then
                        Raise_Error
                          (Params,
                           "Iterator stopped after yielding"
                           & Integer'Image (I) & " elements, the"
                           & Integer'Image (Index) & "th one was expected");
                     end if;
                  end loop;

                  return Create (new Eval_Result_Record'
                    (Kind      => Ada_Node_Value,
                     Ref_Count => <>,
                     Node      => Result));
               end;

            when Field_Access_Value =>
               declare
                  --  We want to be case insensitive, so keep Ident_Cmp to
                  --  perform lower case string comparisons.

                  Node         : Ada_Node renames Name.Value.Field_Node;
                  Ident_Cmp    : constant Wide_Wide_String :=
                     To_Lower (Name.Value.Field_Name.all);
                  Param_Values : constant Eval_Result_Array :=
                     Eval_Params (Params);
               begin
                  case Kind (Node) is
                  when List_Kind =>
                     --  Lists have no field, so we are not supposed to have a
                     --  list in a Filed_Access_Value in the first place.

                     raise Program_Error;

                  % for cls in ctx.astnode_types:
                     % if not cls.abstract:
                        ## Evaluation is supposed to yield always valid
                        ## Field_Access_Value: fields must exist and they must
                        ## accept explicit arguments.
                        <% fields = cls.get_abstract_fields(
                               predicate=lambda f: f.explicit_arguments,
                               include_inherited=True) %>

                        when ${cls.name()}_Kind =>
                           if Ident_Cmp = "" then
                              ## This should not happen, this is just a handy
                              ## case for code generation.
                              raise Program_Error;
                           % for f in fields:
                              <% args = f.explicit_arguments %>
                              elsif Ident_Cmp = "${f.name.lower}" then
                                 ## Make sure there are exactly the number of
                                 ## arguments expected and that these have the
                                 ## expected types.
                                 if Param_Values'Length /= ${len(args)} then
                                    Raise_Error
                                      (Params,
                                       "Invalid number of arguments:"
                                       & " ${len(args)} expected but got "
                                       & Natural'Image (Param_Values'Length));
                                 end if;

                                 declare
                                    % for n, t, _ in args:
                                       ${n} : ${t.name()};
                                    % endfor
                                 begin
                                 % for i, (n, t, _) in enumerate(args):

                                    if Param_Values (${i}).Value.Kind /=
                                       ${enum_for_type(t)}
                                    % if is_ast_node(t):
                                       or else
                                         (Param_Values (${i}).Value.Node
                                            /= null
                                          and then not
                                            (Param_Values (${i}).Value.Node.all
                                             in ${t.name()}_Type'Class))
                                    % endif
                                    then
                                       Raise_Error
                                         (Params.F_Params.Child (${i}),
                                          "Expected ${t.name()} but got " &
                                          Kind_Name (Param_Values
                                            (${i}).Value.Kind));
                                    else
                                       ${n} := ${t.name()}
                                         (Param_Values (${i}).Value
                                          .${field_for_type(t)});
                                    end if;
                                 % endfor

                                 ## Fine, arguments are fine, now let's just
                                 ## evaluate the field itself.

                                 <%
                                    field_access = '{} (Node).{} ({})'.format(
                                       cls.name(), f.name,
                                       ', '.join(
                                          '{} => {}'.format(n, n)
                                          for n, t, _ in args
                                       )
                                    )
                                 %>

                                 % if is_ast_node(f.type):
                                    return Create (new Eval_Result_Record'
                                      (Kind      => Ada_Node_Value,
                                       Ref_Count => <>,
                                       Node      => Ada_Node (${field_access})));
                                 % else:
                                    return Create (new Eval_Result_Record'
                                      (Kind      => ${enum_for_type(f.type)},
                                       Ref_Count => <>,
                                       ${field_for_type(f.type)} =>
                                          ${field_access}));
                                 % endif

                                 end;
                           % endfor
                           else
                              raise Program_Error;
                           end if;
                     % endif
                  % endfor

                  when others =>
                     --  We handle all concrete node types, so this should not
                     --  happen.
                     raise Program_Error;

                  end case;
               end;

            when Find_Builtin_Value =>
               return Eval_Find
                 (Ada_Node (Expr), Name.Value.Find_Root, Params);

            when others =>
               Raise_Error
                 (Expr, "Cannot subscript a " & Kind_Name (Name.Value.Kind));
         end case;
      end Eval_Call;

      ---------------
      -- Eval_Find --
      ---------------

      function Eval_Find
        (Expr   : Ada_Node;
         Root   : Ada_Node;
         Params : Param_List)
         return Eval_Result
      is
         Param_Expr    : Ada_Node;
         Exists        : Boolean;
         Expected_Kind : Ada_Node_Type_Kind := 0;
      begin
         --  Invoke Raise_Error if we have more or less that 1 parameter in
         --  Params.

         if Child_Count (Params) /= 1 then
            Raise_Error (Params, "Exactly one argument is expected: the name"
                                 & " of the kind for searched nodes");
         end if;

         Params.F_Params.Get_Child (0, Exists, Param_Expr);
         pragma Assert (Exists);

         --  Likewise if the kind of the parameter is unexpected or if
         --  it's not a simple form (i.e. X => Y instead of Y).

         if Kind (Param_Expr) /= Param_Assoc_Kind then
            Raise_Error (Params,
                         "Invalid argument: " & Kind_Name (Param_Expr));
         elsif Param_Assoc (Param_Expr).F_Designator /= null then
            Raise_Error (Params, "No designator allowed for .Find methods");
         end if;

         --  Now, try to get an AST node kind out of this expression

         Param_Expr := Ada_Node (Param_Assoc (Param_Expr).F_Expr);
         if Kind (Param_Expr) /= Identifier_Kind then
            Raise_Error
              (Param_Expr,
               "Invalid argument: identifier expected but got "
               & Kind_Name (Param_Expr) & " instead");
         end if;

         declare
            Ident     : constant Wide_Wide_String :=
               Identifier (Param_Expr).F_Tok.Text.all;
            Ident_Cmp : constant Wide_Wide_String := To_Lower (Ident);
         begin
            if Ident_Cmp = "" then
               ## This should not happen, this is just a handy case
               ## for code generation.
               raise Program_Error;
            % for cls in ctx.astnode_types:
               % if not cls.abstract:
                  elsif Ident_Cmp = "${cls.name().lower}" then
                     Expected_Kind := ${cls.name()}_Kind;
               % endif
            % endfor
            else
               Raise_Error (Param_Expr, "Invalid node kind: " & Image (Ident));
            end if;
         end;

         return Create (new Eval_Result_Record'
           (Kind      => Ada_Node_Iterator_Value,
            Ref_Count => <>,
            Node_Iter => new Find_Iterator'
              (Find (Root,
                     new Ada_Node_Kind_Filter'(Kind => Expected_Kind)))));
      end Eval_Find;

      ---------------------
      -- Eval_Identifier --
      ---------------------

      function Eval_Identifier (Expr : Identifier) return Eval_Result is
         Ident     : constant Wide_Wide_String := Expr.F_Tok.Text.all;
         Ident_Cmp : constant Wide_Wide_String := To_Lower (Ident);
      begin
         --  The only identifier available so far is the analysis unit root
         --  node.

         if Ident_Cmp = "root" then
            return Create (new Eval_Result_Record'
              (Kind => Ada_Node_Value, Ref_Count => <>, Node => Root));

         else
            Raise_Error
              (Expr, "Undefined identifier: " & Image (Ident));
         end if;
      end Eval_Identifier;

      -----------------
      -- Eval_Prefix --
      -----------------

      function Eval_Prefix (Expr : Prefix) return Eval_Result is
         Pref  : constant Eval_Result := Eval (Expr.F_Prefix);
         Ident : Symbol_Type;
      begin
         --  The only prefix form we handle here is X.Y where X is any valid
         --  expression and Y is a static name.

         if Kind (Expr.F_Suffix) /= Identifier_Kind then
            Raise_Error (Expr,
                         "Invalid " & Kind_Name (Expr.F_Suffix)
                         & " suffix (Identifier expected)");
         end if;
         Ident := Get_Symbol (Identifier (Expr.F_Suffix).F_Tok);

         declare
            --  We want to be case insensitive, so keep Ident_Cmp to perform
            --  lower case string comparisons.

            Ident_Cmp : constant Wide_Wide_String :=
               To_Lower (Ident.all);
         begin
            --  Now, field access (validation) completely depends of the prefix
            --  used in the expression.

            case Pref.Value.Kind is

            --  If the prefix is a structure, then we know directly the set of
            --  valid fields.

            % for cls in ctx.sorted_types(ctx.struct_types):
               when ${enum_for_type(cls)} =>
                  <% fields = cls.get_abstract_fields(
                                  include_inherited=True) %>
                  if Ident_Cmp = "" then
                     ## This should not happen, this is just a handy case
                     ## for code generation.
                     raise Program_Error;
                  % for f in fields:
                     <%
                        field_access = 'Pref.Value.{}.{}'.format(
                           field_for_type(cls), f.name
                        )
                     %>
                     elsif Ident_Cmp = "${f.name.lower}" then
                     % if is_ast_node(f.type):
                        return Create (new Eval_Result_Record'
                          (Kind      => Ada_Node_Value,
                           Ref_Count => <>,
                           Node      => Ada_Node (${field_access})));
                     % else:
                        return Create (new Eval_Result_Record'
                          (Kind      => ${enum_for_type(f.type)},
                           Ref_count => <>,
                           ${field_for_type(f.type)} => ${field_access}));
                     % endif
                  % endfor
                  else
                     Raise_Error
                       (Expr.F_Suffix,
                        "${cls.name()} has no " & Image (Ident.all)
                        & " field; valid ones are:"
                        % for f in fields:
                           & " ${f.name}"
                        % endfor
                        );
                  end if;
            % endfor

            --  If the prefix is an AST node, we have first to get the kind of
            --  the node in order to know what (possibly inheritted) fields are
            --  available.

            when Ada_Node_Value =>

               --  Special case: "Find" is not a field, but we use this syntax
               --  to perform AST node lookup.

               if Ident_Cmp = "find" then
                  return Create (new Eval_Result_Record'
                    (Kind      => Find_Builtin_Value,
                     Ref_Count => <>,
                     Find_Root => Pref.Value.Node));
               end if;

               case Kind (Pref.Value.Node) is
               when List_Kind =>
                  Raise_Error (Expr, "Lists have no field");

               % for cls in ctx.astnode_types:
                  % if not cls.abstract:
                     <% fields = cls.get_abstract_fields(
                                     include_inherited=True) %>
                     when ${cls.name()}_Kind =>
                        if Ident_Cmp = "" then
                           ## This should not happen, this is just a handy
                           ## case for code generation.
                           raise Program_Error;
                        % for f in fields:
                           <%
                              field_access = '{} (Pref.Value.Node).{}'.format(
                                 cls.name(), f.name
                              )
                           %>
                           elsif Ident_Cmp = "${f.name.lower}" then
                           % if f.explicit_arguments:
                              return Create (new Eval_Result_Record'
                                (Kind       => Field_Access_Value,
                                 Ref_Count  => <>,
                                 Field_Node => Pref.Value.Node,
                                 Field_Name => Ident));
                           % elif is_ast_node(f.type):
                              return Create (new Eval_Result_Record'
                                (Kind      => Ada_Node_Value,
                                 Ref_Count => <>,
                                 Node      => Ada_Node (${field_access})));
                           % else:
                              return Create (new Eval_Result_Record'
                                (Kind      => ${enum_for_type(f.type)},
                                 Ref_Count => <>,
                                 ${field_for_type(f.type)} =>
                                    ${field_access}));
                           % endif
                        % endfor
                        else
                           Raise_Error
                             (Expr.F_Suffix,
                              "${cls.name()} has no " & Image (Ident.all)
                              & " field; valid ones are:"
                              % for f in fields:
                                 & " ${f.name}"
                              % endfor
                              );
                        end if;
                  % endif
               % endfor

               when others =>
                  --  We handle all concrete node types, so this should not
                  --  happen.
                  raise Program_Error;
               end case;

            when Error_Value =>
               raise Program_Error;

            when others =>
               Raise_Error
                 (Expr, Kind_Name (Pref.Value.Kind) & " have no field");
            end case;
         end;
      end Eval_Prefix;

      -----------------
      -- Raise_Error --
      -----------------

      procedure Raise_Error
        (Expr    : access Ada_Node_Type'Class;
         Message : String)
      is
      begin
         Error.Sub_Expr := Ada_Node (Expr);
         Error.Message := +Message;
         raise Evaluation_Error;
      end Raise_Error;

   begin
      return Eval (E.Root);
   exception
      when Evaluation_Error =>
         return Create (new Eval_Result_Record'
           (Kind      => Error_Value,
            Ref_Count => <>,
            Sub_Expr  => Error.Sub_Expr,
            Message   => Error.Message));
   end Eval;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Value : in out Eval_Result_Access) is
      procedure Free is new Ada.Unchecked_Deallocation
        (Eval_Result_Record, Eval_Result_Access);
   begin
      case Value.Kind is
         % for cls in ctx.sorted_types(ctx.array_types):
            when ${enum_for_type(cls)} =>
               Destroy (Value.${field_for_type(cls)});
         % endfor

         when Ada_Node_Iterator_Value =>
            Ada_Node_Iterators.Destroy (Value.Node_Iter);

         when others => null;
      end case;
      Free (Value);
   end Destroy;

   ------------
   -- Adjust --
   ------------

   overriding
   procedure Adjust (V : in out Eval_Result) is
   begin
      if V.Value /= null then
         V.Value.Ref_Count := V.Value.Ref_Count + 1;
      end if;
   end Adjust;

   --------------
   -- Finalize --
   --------------

   overriding
   procedure Finalize (V : in out Eval_Result) is
   begin
      if V.Value = null then
         return;
      end if;

      declare
         Ref_Count : Natural renames V.Value.Ref_Count;
      begin
         Ref_Count := Ref_Count - 1;
         if Ref_Count = 0 then
            Destroy (V.Value);
         end if;
      end;
   end Finalize;

end Libadalang.AST.Types.Parsers.Test;
