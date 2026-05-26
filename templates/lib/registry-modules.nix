{ inputs, lib }:

let
  emptyRegistry = {
    official = {};
    community = {};
    private = {};
  };

  modulesFor = registry:
    if registry ? nixosApps then
      registry.nixosApps
    else if registry ? nixosModules then
      registry.nixosModules
    else
      {};

  publicModules =
    if inputs ? appRegistry then
      modulesFor inputs.appRegistry
    else
      {};

  privateModules =
    if inputs ? privateAppRegistry then
      modulesFor inputs.privateAppRegistry
    else
      {};
in
lib.recursiveUpdate emptyRegistry (lib.recursiveUpdate publicModules privateModules)