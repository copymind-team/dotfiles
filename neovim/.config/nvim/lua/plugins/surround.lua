return {
  "kylechui/nvim-surround",
  version = "^3.0.0", -- Use for stability; omit to use `main` branch for the latest features
  event = "VeryLazy",
  config = function()
    require("nvim-surround").setup({})

    local surround = require("nvim-surround")
    for _, name in ipairs({ "insert_surround", "normal_surround", "delete_surround", "change_surround" }) do
      local original = surround[name]
      surround[name] = function(...)
        if not vim.bo.modifiable then
          return
        end
        return original(...)
      end
    end
  end,
}
