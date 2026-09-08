{
  flake.templates = rec {
    terranix-consul = {
      path = ../templates/terranix-consul;
      description = "Populate Consul KV from ngnix config via terranix + the Terraform consul provider";
    };
    default = terranix-consul;
  };
}
