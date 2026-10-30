using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OS7.App.Containers.ViewModels;

/// <summary>
/// The smallest possible <see cref="INotifyPropertyChanged"/> — the same one
/// the other two applications carry, and for the same measured reason
/// (docs/SESSION-AVALONIA-FOOTPRINT.md): no toolkit package for one file.
/// </summary>
public abstract class ViewModelBase : INotifyPropertyChanged
{
	public event PropertyChangedEventHandler? PropertyChanged;

	protected void Raise([CallerMemberName] string? name = null) =>
		PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

	protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
	{
		if (EqualityComparer<T>.Default.Equals(field, value))
		{
			return false;
		}

		field = value;
		Raise(name);
		return true;
	}
}
