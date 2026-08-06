using System.Runtime.InteropServices;
using DXP;
using ProvenMetal;

namespace CSharpPlugin
{
    // Altium's plugin loader instantiates this COM-visible class and calls
    // InvokePluginFactory to obtain the server module. Class name and signature
    // must match Altium's convention (same shape used by shipping C# extensions).
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public class PluginFactory
    {
        public object InvokePluginFactory(IClient client)
        {
            return new ProvenMetalModule(client);
        }
    }
}
