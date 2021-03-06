with Ada.Command_Line;
with Ada.Containers.Generic_Array_Sort;
with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNATCOLL.Projects; use GNATCOLL.Projects;
with GNATCOLL.Traces;
with GNATCOLL.VFS;      use GNATCOLL.VFS;

with Langkit_Support.Adalog.Debug;   use Langkit_Support.Adalog.Debug;
with Langkit_Support.Slocs;          use Langkit_Support.Slocs;
with Langkit_Support.Text;           use Langkit_Support.Text;
with Libadalang.Analysis;            use Libadalang.Analysis;
with Libadalang.Iterators;           use Libadalang.Iterators;
with Libadalang.Unit_Files;          use Libadalang.Unit_Files;
with Libadalang.Unit_Files.Projects; use Libadalang.Unit_Files.Projects;

pragma Warnings (Off, "referenced");
pragma Warnings (Off, "use clause for package");
with Libadalang.Analysis.Properties; use Libadalang.Analysis.Properties;
pragma Warnings (On, "use clause for package");
pragma Warnings (On, "referenced");

with Put_Title;

procedure Nameres is

   package String_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);

   --  Holders for options that command-line can tune

   Charset : Unbounded_String := To_Unbounded_String ("");
   --  Charset to use in order to parse analysis units

   Quiet   : Boolean := False;
   --  If True, don't display anything but errors on standard output

   UFP     : Unit_Provider_Access;
   --  When project file handling is enabled, corresponding unit provider

   Ctx     : Analysis_Context := No_Analysis_Context;

   Resolve_All          : Boolean := False;
   --  Whether to run the tool in "resolve all cross references" mode. In that
   --  mode, pragmas are ignored.

   Solve_Line           : Natural := 0;
   --  If passed, the tool will ignore all pragmas, ignore --all, and only
   --  solve the node at given line.

   Only_Show_Failures   : Boolean := False;
   --  Only print failures to stdout

   Dump_Envs            : Boolean := False;
   --  Dump lexical envs of every explicitly passed file

   Timeout : Natural := 100_000;
   --  Logic resolution timeout

   function Text (N : Ada_Node'Class) return String is (Image (Text (N)));

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Strip_Prefix (S, Prefix : String) return String is
     (S (S'First + Prefix'Length .. S'Last));

   function "+" (S : String) return Unbounded_String
      renames To_Unbounded_String;
   function "+" (S : Unbounded_String) return String renames To_String;

   function "<" (Left, Right : Ada_Node) return Boolean is
     (Sloc_Range (Left).Start_Line < Sloc_Range (Right).Start_Line);
   procedure Sort is new Ada.Containers.Generic_Array_Sort
     (Index_Type   => Positive,
      Element_Type => Ada_Node,
      Array_Type   => Ada_Node_Array,
      "<"          => "<");

   function Decode_Boolean_Literal (T : Text_Type) return Boolean is
     (Boolean'Wide_Wide_Value (T));
   procedure Process_File (Unit : Analysis_Unit; Filename : String);

   procedure Add_Files_From_Project
     (PT    : Project_Tree_Access;
      P     : Project_Type;
      Files : in out String_Vectors.Vector);

   function Do_Pragma_Test (Arg : Expr) return Ada_Node_Array is
     (P_Matching_Nodes (Arg));
   --  Do the resolution associated to a Test pragma.
   --
   --  This function is here to provide a simple breakpoint location for
   --  debugging sessions.

   procedure New_Line;
   procedure Put_Line (S : String);
   procedure Put (S : String);
   procedure Resolve_Node (Node : Ada_Node);
   procedure Resolve_Block (Block : Ada_Node);

   --------------
   -- New_Line --
   --------------

   procedure New_Line is
   begin
      if not Quiet then
         Ada.Text_IO.New_Line;
      end if;
   end New_Line;

   --------------
   -- Put_Line --
   --------------

   procedure Put_Line (S : String) is begin
      if not Quiet then
         Ada.Text_IO.Put_Line (S);
      end if;
   end Put_Line;

   ---------
   -- Put --
   ---------

   procedure Put (S : String) is begin
      if not Quiet then
         Ada.Text_IO.Put (S);
      end if;
   end Put;

   ----------------
   -- Safe_Image --
   ----------------

   function Safe_Image (Node : Ada_Node'Class) return String is
     (Image (Short_Image (Node)));

   ------------------
   -- Resolve_Node --
   ------------------

   procedure Resolve_Node (Node : Ada_Node) is

      function Print_Node (N : Ada_Node'Class) return Visit_Status;

      ----------------
      -- Print_Node --
      ----------------

      function Print_Node (N : Ada_Node'Class) return Visit_Status is
      begin
         if Kind (N) in Ada_Expr then
            declare
               P_Ref  : constant Basic_Decl := P_Referenced_Decl (As_Expr (N));
               P_Type : constant Base_Type_Decl :=
                  P_Expression_Type (As_Expr (N));
            begin
               if not Quiet then
                  Put_Line ("Expr: " & Safe_Image (N));
                  Put_Line ("  references: " & Image (P_Ref));
                  Put_Line ("  type:       " & Image (P_Type));
               end if;
            end;
         end if;
         return (if P_Xref_Entry_Point (N) and As_Ada_Node (N) /= Node
                 then Over else Into);
      end Print_Node;

      Dummy : Visit_Status;

   begin
      if not (Quiet or else Only_Show_Failures) then
         Put_Title ('*', "Resolving xrefs for node " & Safe_Image (Node));
      end if;
      if Langkit_Support.Adalog.Debug.Debug then
         Assign_Names_To_Logic_Vars (Node);
      end if;

      if P_Resolve_Names (Node) then
         if not Only_Show_Failures then
            Dummy := Traverse (Node, Print_Node'Access);
         end if;
      else
         Put_Line ("Resolution failed for node " & Safe_Image (Node));
      end if;
      if not (Quiet or else Only_Show_Failures) then
         Put_Line ("");
      end if;
   exception
      when E : others =>
         Put_Line
           ("Resolution failed with exception for node " & Safe_Image (Node));
         Put_Line ("> " & Ada.Exceptions.Exception_Information (E));
         Put_Line ("");
   end Resolve_Node;

   -------------------
   -- Resolve_Block --
   -------------------

   procedure Resolve_Block (Block : Ada_Node) is
      function Is_Xref_Entry_Point (N : Ada_Node) return Boolean
      is (P_Xref_Entry_Point (N)
          and then (Solve_Line = 0
                    or else Natural (Sloc_Range (N).Start_Line) = Solve_Line));
   begin
      for Node of Find (Block, Is_Xref_Entry_Point'Access).Consume loop
         Resolve_Node (Node);
      end loop;
   end Resolve_Block;

   ------------------
   -- Process_File --
   ------------------

   procedure Process_File (Unit : Analysis_Unit; Filename : String) is
   begin
      if Has_Diagnostics (Unit) then
         for D of Diagnostics (Unit) loop
            Put_Line (Format_GNU_Diagnostic (Unit, D));
         end loop;
         return;
      end if;
      Populate_Lexical_Env (Unit);

      if Dump_Envs then
         Put_Title ('-', "Dumping envs for " & Filename);
         Dump_Lexical_Env (Unit);
      end if;

      if Resolve_All or Solve_Line /= 0 then
         Resolve_Block (Root (Unit));
      end if;

      declare
         --  Configuration for this unit
         Display_Slocs        : Boolean := False;
         Display_Short_Images : Boolean := False;

         Empty     : Boolean := True;
         Last_Line : Natural := 0;
         P_Node    : Pragma_Node;

         function Is_Pragma_Node (N : Ada_Node) return Boolean is
           (Kind (N) = Ada_Pragma_Node);

         function Pragma_Name return String is (Text (F_Tok (F_Id (P_Node))));

         procedure Handle_Pragma_Config (Id : Identifier; E : Expr);

         --------------------------
         -- Handle_Pragma_Config --
         --------------------------

         procedure Handle_Pragma_Config (Id : Identifier; E : Expr) is
            Name : constant Text_Type := Text (F_Tok (Id));
         begin
            if Kind (E) /= Ada_Identifier then
               raise Program_Error with
                 ("Invalid config value for " & Image (Name, True) & ": "
                  & Text (E));
            end if;

            declare
               Value : constant Text_Type := Text (F_Tok (As_Identifier (E)));
            begin
               if Name = "Display_Slocs" then
                  Display_Slocs := Decode_Boolean_Literal (Value);
               elsif Name = "Display_Short_Images" then
                  Display_Short_Images := Decode_Boolean_Literal (Value);
               else
                  raise Program_Error with
                    ("Invalid configuration: " & Image (Name, True));
               end if;
            end;
         end Handle_Pragma_Config;

      begin
         --  Print what entities are found for expressions X in all the "pragma
         --  Test (X)" we can find in this unit.
         for Node of Find (Root (Unit), Is_Pragma_Node'Access).Consume loop

            P_Node := As_Pragma_Node (Node);

            --  If this pragma and the previous ones are not on adjacent lines,
            --  do not make them adjacent in the output.
            if Pragma_Name /= "Config" then
               if Last_Line /= 0
                     and then
                  Natural (Sloc_Range (Node).Start_Line) - Last_Line > 1
               then
                  New_Line;
               end if;
               Last_Line := Natural (Sloc_Range (Node).End_Line);
            end if;

            if Pragma_Name = "Config" then
               --  Handle testcase configuration pragmas for this file
               for Arg of Ada_Node_Array'(Children (F_Args (P_Node))) loop
                  declare
                     A : constant Pragma_Argument_Assoc :=
                        As_Pragma_Argument_Assoc (Arg);
                  begin
                     if Is_Null (F_Id (A)) then
                        raise Program_Error with
                           "Name missing in pragma Config";
                     elsif Kind (F_Id (A)) /= Ada_Identifier then
                        raise Program_Error with
                           "Name in pragma Config must be an identifier";
                     end if;

                     Handle_Pragma_Config (F_Id (A), F_Expr (A));
                  end;
               end loop;

            elsif Pragma_Name = "Section" then
               --  Print headlines
               declare
                  pragma Assert (Child_Count (F_Args (P_Node)) = 1);
                  Arg : constant Expr :=
                     P_Assoc_Expr (As_Base_Assoc (Child (F_Args (P_Node), 1)));
                  pragma Assert (Kind (Arg) = Ada_String_Literal);

                  Tok : constant Token_Type := F_Tok (As_String_Literal (Arg));
                  T   : constant Text_Type := Text (Tok);
               begin
                  if not Quiet then
                     Put_Title ('-', Image (T (T'First + 1 .. T'Last - 1)));
                  end if;
               end;
               Empty := True;

            elsif Pragma_Name = "Test" then
               --  Perform name resolution
               declare
                  pragma Assert (Child_Count (F_Args (P_Node)) in 1 | 2);

                  Arg      : constant Expr :=
                     P_Assoc_Expr (As_Base_Assoc (Child (F_Args (P_Node), 1)));

                  Debug_Lookup : Boolean := False;

               begin
                  if Child_Count (F_Args (P_Node)) = 2 then
                     Debug_Lookup := Text
                       (P_Assoc_Expr (As_Base_Assoc
                         (Child (F_Args (P_Node), 2))))
                          = String'("Debug");
                  end if;

                  Trigger_Envs_Debug (Debug_Lookup);

                  declare
                     Entities : Ada_Node_Array := Do_Pragma_Test (Arg);
                  begin

                     Put_Line (Text (Arg) & " resolves to:");
                     Sort (Entities);
                     for E of Entities loop
                        Put ("    " & (if Display_Short_Images
                                       then Image (Short_Image (E))
                                       else Text (E)));
                        if Display_Slocs then
                           Put_Line (" at "
                                     & Image (Start_Sloc (Sloc_Range (E))));
                        else
                           New_Line;
                        end if;
                     end loop;
                     if Entities'Length = 0 then
                        Put_Line ("    <none>");
                     end if;
                  end;
               end;

               Empty := False;
               Trigger_Envs_Debug (False);

            elsif Pragma_Name = "Test_Statement" then
               pragma Assert (Child_Count (F_Args (P_Node)) = 0);
               Resolve_Node (Previous_Sibling (P_Node));
               Empty := False;

            elsif Pragma_Name = "Test_Block" then
               pragma Assert (Child_Count (F_Args (P_Node)) = 0);
               declare
                  Parent_1 : constant Ada_Node := Parent (P_Node);
                  Parent_2 : constant Ada_Node := Parent (Parent_1);
               begin
                  Resolve_Block
                    (if Kind (Parent_2) = Ada_Compilation_Unit
                     then F_Body (As_Compilation_Unit (Parent_2))
                     else Previous_Sibling (P_Node));
               end;
               Empty := False;
            end if;
         end loop;
         if not Empty then
            New_Line;
         end if;
      end;
   end Process_File;

   ----------------------------
   -- Add_Files_From_Project --
   ----------------------------

   procedure Add_Files_From_Project
     (PT    : Project_Tree_Access;
      P     : Project_Type;
      Files : in out String_Vectors.Vector)
   is
      List : File_Array_Access := P.Source_Files;
   begin
      for F of List.all loop
         declare
            FI        : constant File_Info := PT.Info (F);
            Full_Name : Filesystem_String renames F.Full_Name.all;
            Name      : constant String := +Full_Name;
         begin
            if FI.Language = "ada" then
               Files.Append (+Name);
            end if;
         end;
      end loop;
      Unchecked_Free (List);
   end Add_Files_From_Project;

   Files : String_Vectors.Vector;

   With_Default_Project : Boolean := False;
   Project_File         : Unbounded_String;
   Scenario_Vars        : String_Vectors.Vector;
   Files_From_Project   : Boolean := False;
   Discard_Errors       : Boolean := False;

begin

   GNATCOLL.Traces.Parse_Config_File;

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      declare
         Arg : constant String := Ada.Command_Line.Argument (I);
      begin
         if Arg in "--quiet" | "-q" then
            Quiet := True;
         elsif Arg in "--trace" | "-T" then
            Set_Debug_State (Trace);
         elsif Arg in "--discard-errors-in-populate-lexical-env" | "-d" then
            Discard_Errors := True;
         elsif Arg in "--debug" | "-D" then
            Set_Debug_State (Step);
         elsif Arg = "--step-on-fail" then
            Set_Debug_State (Step_At_First_Unsat);
         elsif Starts_With (Arg, "--charset") then
            Charset := +Strip_Prefix (Arg, "--charset=");
         elsif Arg in "--with-default-project" | "-DP" then
            With_Default_Project := True;
         elsif Arg in "--print-envs" | "-E" then
            Dump_Envs := True;
         elsif Arg = "--all" then
            Resolve_All := True;
         elsif Arg = "--only-show-failures" then
            Only_Show_Failures := True;
         elsif Arg = "--files-from-project" then
            Files_From_Project := True;
         elsif Starts_With (Arg, "-P") then
            Project_File := +Strip_Prefix (Arg, "-P");
         elsif Starts_With (Arg, "-L") then
            Solve_Line := Positive'Value (Strip_Prefix (Arg, "-L"));
         elsif Starts_With (Arg, "-t") then
            Timeout := Natural'Value (Strip_Prefix (Arg, "-t"));
         elsif Starts_With (Arg, "-X") then
            Scenario_Vars.Append (+Strip_Prefix (Arg, "-X"));
         elsif Starts_With (Arg, "--") then
            Put_Line ("Invalid argument: " & Arg);
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         else
            Files.Append (+Arg);
         end if;
      end;
   end loop;

   if With_Default_Project or else Length (Project_File) > 0 then
      declare
         Filename : constant String := +Project_File;
         Env      : Project_Environment_Access;
         Project  : constant Project_Tree_Access := new Project_Tree;
      begin
         Initialize (Env);

         --  Set scenario variables
         for Assoc of Scenario_Vars loop
            declare
               A        : constant String := +Assoc;
               Eq_Index : Natural := A'First;
            begin
               while Eq_Index <= A'Length and then A (Eq_Index) /= '=' loop
                  Eq_Index := Eq_Index + 1;
               end loop;
               if Eq_Index not in A'Range then
                  Put_Line ("Invalid scenario variable: -X" & A);
                  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
                  return;
               end if;
               Change_Environment
                 (Env.all,
                  A (A'First .. Eq_Index - 1),
                  A (Eq_Index + 1 .. A'Last));
            end;
         end loop;

         if Filename'Length = 0 then
            Load_Empty_Project (Project.all, Env);
            Project.Root_Project.Delete_Attribute (Source_Dirs_Attribute);
            Project.Root_Project.Delete_Attribute (Languages_Attribute);
            Project.Recompute_View;
         else
            Load (Project.all, Create (+Filename), Env);
         end if;
         UFP := new Project_Unit_Provider_Type'(Create (Project, Env, True));

         if Files_From_Project then
            Add_Files_From_Project (Project, Project.Root_Project, Files);
         end if;
      end;
   end if;

   Ctx := Create
     (Charset       => +Charset,
      Unit_Provider => Unit_Provider_Access_Cst (UFP));
   Discard_Errors_In_Populate_Lexical_Env (Ctx, Discard_Errors);
   Set_Logic_Resolution_Timeout (Ctx, Timeout);

   for F of Files loop
      declare
         File : constant String := +F;
         Unit : Analysis_Unit;
      begin
         Unit := Get_From_File (Ctx, File);

         if not Quiet then
            Put_Title ('#', "Analyzing " & File);
         end if;
         Process_File (Unit, File);
      end;
   end loop;

   Destroy (Ctx);
   Destroy (UFP);
   Put_Line ("Done.");
exception
   when others =>
      Put_Line ("Traceback:");
      Put_Line ("");
      raise;
end Nameres;
