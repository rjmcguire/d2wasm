/**
 * WASM Section Builders
 * 
 * Each module provides a build*Section() function that returns
 * raw section content (without section ID/length prefix).
 */
module codegen.wasm.sections;

public import codegen.wasm.sections.type_ : FuncSig, buildTypeSection;
public import codegen.wasm.sections.import_ : ImportInfo, buildImportSection;
public import codegen.wasm.sections.function_ : buildFunctionSection;
public import codegen.wasm.sections.memory : buildMemorySection;
public import codegen.wasm.sections.global : GlobalInfo, buildGlobalSection;
public import codegen.wasm.sections.export_ : FuncExport, GlobalExport, buildExportSection;
public import codegen.wasm.sections.code : buildCodeSection;
public import codegen.wasm.sections.data : DataEntry, buildDataSection;
