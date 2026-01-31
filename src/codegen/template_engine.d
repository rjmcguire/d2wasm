/**
 * Template Engine for D-to-WASM Compiler
 * 
 * This module implements a simple template substitution system for generating
 * WebAssembly Text Format (WAT) from AST nodes.
 */
module codegen.template_engine;

import std.string;
import std.array;
import std.file;
import std.path;
import std.stdio;

/**
 * Interface for template substitution
 */
interface TemplateEngine {
    /**
     * Substitute parameters in a template and return the result
     */
    string substitute(string templateName, string[string] parameters);
    
    /**
     * Load a template from a string
     */
    void loadTemplate(string name, string watContent);
    
    /**
     * Load all templates from a directory
     */
    void loadFromDirectory(string directoryPath);
    
    /**
     * Get list of available templates
     */
    string[] getAvailableTemplates();
}

/**
 * Simple implementation of TemplateEngine
 */
class SimpleTemplateEngine : TemplateEngine {
    private string[string] templates;
    private string baseDirectory;

    this(string baseDirectory = "templates") {
        this.baseDirectory = baseDirectory;
        if (exists(baseDirectory)) {
            loadFromDirectory(baseDirectory);
        }
    }

    override string substitute(string templateName, string[string] parameters) {
        auto ptr = templateName in templates;
        if (!ptr) {
            // Try to load it on demand if not pre-loaded
            string path = buildPath(baseDirectory, templateName ~ ".wat");
            if (exists(path)) {
                string content = readText(path);
                templates[templateName] = content;
                ptr = &templates[templateName];
            } else {
                throw new Exception("Template not found: " ~ templateName);
            }
        }

        string result = *ptr;
        foreach (key, value; parameters) {
            string placeholder = "${" ~ key ~ "}";
            result = result.replace(placeholder, value);
        }
        
        return result;
    }

    override void loadTemplate(string name, string watContent) {
        templates[name] = watContent;
    }

    override void loadFromDirectory(string directoryPath) {
        if (!exists(directoryPath)) return;

        foreach (DirEntry entry; dirEntries(directoryPath, SpanMode.depth)) {
            if (entry.isFile && entry.name.endsWith(".wat")) {
                string relativePath = relativePath(entry.name, directoryPath);
                // Strip extension for template name
                string templateName = stripExtension(relativePath);
                templates[templateName] = readText(entry.name);
            }
        }
    }

    override string[] getAvailableTemplates() {
        return templates.keys;
    }
}
